if Code.ensure_loaded?(Ecto.Multi) do
  defmodule Shigoto.Multi do
    @moduledoc """
    > **Deprecated.** Use `Shigoto.Executor` instead.
    >
    > `Shigoto.Executor` evaluates workflow nodes eagerly outside any DB
    > transaction and returns an `Ecto.Multi` containing only the `persists`
    > changesets for the caller to commit.

    Converts Shigoto workflows into `Ecto.Multi`.

    This module is an optional execution adapter.

    It maps Shigoto nodes as follows:

      * `assert` function call -> `Ecto.Multi.run/3`
      * `task` function call -> `Ecto.Multi.run/3`
      * `task` workflow call -> `Ecto.Multi.merge/2`
      * `decision` -> `Ecto.Multi.run/3` + selected-branch `Ecto.Multi.merge/2`
      * `emit` -> `Ecto.Multi.run/3`

    `emit` does not define delivery semantics by itself.

    The caller should pass an emitter callback and decide whether to use
    fire-and-forget, an outbox pattern, or any other event delivery mechanism.
    """

    alias Ecto.Multi

    @type inputs :: map() | keyword()
    @type workflow_name :: atom()
    @type event_ref :: atom() | {module(), atom()}

    @type emit_callback ::
            nil
            | function()
            | {module(), atom(), arity()}
            | {module(), atom(), [term()]}

    @doc """
    Decodes an opaque Ecto.Multi operation key produced by Shigoto.

    Returns `{:ok, {workflow_context, logical_name}}` or `:error`.

    The `workflow_context` is the last element of the internal prefix path
    (i.e., the workflow or task name that produced this operation), or `nil`
    for top-level operations.
    """
    @spec decode_error(term()) :: {:ok, {atom() | nil, term()}} | :error
    def decode_error({:shigoto, prefix, logical_name}) when is_list(prefix) do
      {:ok, {List.last(prefix), logical_name}}
    end

    def decode_error(_), do: :error

    @doc """
    Builds an `Ecto.Multi` from a Shigoto workflow module and workflow name.

    ## Options

      * `:emit` - callback used by `emit` nodes.
      * `:workflow_resolver` - custom resolver for workflow calls.
      * `:prefix` - internal operation-name prefix.
      * `:module` - current workflow module. Usually set automatically.

    ## Emit callback forms

    Anonymous functions:

      * `fn payload -> ... end`
      * `fn event, payload -> ... end`
      * `fn repo, event, payload -> ... end`
      * `fn repo, changes, event, payload -> ... end`
      * `fn repo, changes, event, payload, emit -> ... end`

    MFA callbacks:

      * `{Mod, :fun, 1}` calls `Mod.fun(payload)`
      * `{Mod, :fun, 2}` calls `Mod.fun(event, payload)`
      * `{Mod, :fun, 3}` calls `Mod.fun(repo, event, payload)`
      * `{Mod, :fun, 4}` calls `Mod.fun(repo, changes, event, payload)`
      * `{Mod, :fun, 5}` calls `Mod.fun(repo, changes, event, payload, emit)`

    MFA with extra args:

      * `{Mod, :fun, extra_args}` calls
        `Mod.fun(repo, changes, event, payload, extra_args...)`

    Callback results are normalized:

      * `{:ok, value}` is kept
      * `{:error, reason}` is kept
      * any other value becomes `{:ok, value}`
    """
    @spec new(module(), workflow_name(), inputs(), keyword()) :: Ecto.Multi.t()
    def new(module, workflow_name, inputs \\ %{}, opts \\ []) do
      workflow = fetch_workflow!(module, workflow_name)

      opts =
        opts
        |> Keyword.put_new(:module, module)
        |> Keyword.put_new(:prefix, [])

      from_workflow(workflow, inputs, opts)
    end

    @doc """
    Builds an `Ecto.Multi` from a workflow struct.
    """
    @spec from_workflow(struct(), inputs(), keyword()) :: Ecto.Multi.t()
    def from_workflow(workflow, inputs \\ %{}, opts \\ []) do
      prefix = Keyword.get(opts, :prefix, [])

      Multi.new()
      |> put_inputs(workflow, inputs, prefix)
      |> compile_region(workflow, all_vertices(workflow), opts)
    end

    @doc """
    Alias for `from_workflow/3`.
    """
    @spec to_multi(struct(), inputs(), keyword()) :: Ecto.Multi.t()
    def to_multi(workflow, inputs \\ %{}, opts \\ []) do
      from_workflow(workflow, inputs, opts)
    end

    @doc """
    Builds an `Ecto.Multi` from an automation and an event payload.

    This is useful when an external event should start a workflow.

    The automation's `map` entries are used to convert event payload into
    workflow inputs.
    """
    @spec from_automation(module(), atom(), map() | keyword(), keyword()) :: Ecto.Multi.t()
    def from_automation(module, automation_name, event_payload, opts \\ []) do
      automation = fetch_automation!(module, automation_name)
      workflow = fetch_workflow!(module, automation.run)

      inputs =
        automation.mappings
        |> list()
        |> Map.new(fn mapping ->
          {mapping_target(mapping), resolve_event_payload_path!(event_payload, mapping.from)}
        end)

      opts =
        opts
        |> Keyword.put_new(:module, module)
        |> Keyword.put_new(:prefix, [])

      from_workflow(workflow, inputs, opts)
    end

    defp compile_region(multi, workflow, region_vertices, opts) do
      region_vertices = MapSet.new(region_vertices)
      graph = Shigoto.Graph.workflow_graph(workflow)

      {:ok, topsort} =
        Shigoto.Graph.validate_acyclic(
          graph,
          "workflow #{inspect(workflow.name)}"
        )

      node_index = node_index(workflow)

      branch_descendants =
        branch_descendants_for_decisions(workflow, graph, region_vertices)

      main_vertices =
        MapSet.difference(region_vertices, branch_descendants)

      topsort
      |> Enum.filter(&MapSet.member?(main_vertices, &1))
      |> Enum.reduce(multi, fn vertex, multi ->
        case Map.fetch(node_index, vertex) do
          {:ok, {kind, node}} ->
            add_node(multi, workflow, kind, node, opts)

          :error ->
            multi
        end
      end)
      |> add_persist_steps(workflow, opts)
    end

    defp add_persist_steps(multi, workflow, opts) do
      prefix = Keyword.get(opts, :prefix, [])

      workflow.persists
      |> list()
      |> Enum.reduce(multi, fn persist_name, m ->
        value_op = op_name(prefix, persist_name)
        persist_op = op_name(prefix, {:persist, persist_name})

        Multi.merge(m, fn changes ->
          case Map.fetch(changes, value_op) do
            {:ok, value} when not is_nil(value) ->
              changeset_like_to_multi(value, persist_op, prefix)

            _ ->
              Multi.new()
          end
        end)
      end)
    end

    defp changeset_like_to_multi(%Shigoto.Ecto.ChangesetMulti{} = cm, _op, prefix) do
      Shigoto.Ecto.ChangesetMulti.to_multi(cm, prefix)
    end

    defp changeset_like_to_multi(
           %Ecto.Changeset{data: %_{__meta__: %{state: :built}}} = cs,
           op,
           _prefix
         ) do
      Multi.insert(Multi.new(), op, cs)
    end

    defp changeset_like_to_multi(%Ecto.Changeset{} = cs, op, _prefix) do
      Multi.update(Multi.new(), op, cs)
    end

    defp changeset_like_to_multi(_other, _op, _prefix), do: Multi.new()

    defp add_node(multi, _workflow, :assert, assertion, opts) do
      prefix = Keyword.get(opts, :prefix, [])
      op = op_name(prefix, {:assert, assertion.name})

      Multi.run(multi, op, fn repo, changes ->
        case assertion.evaluated_by do
          {module, function, arg_spec} when is_list(arg_spec) ->
            invoke_with_spec({module, function, arg_spec}, repo, changes, prefix)
            |> normalize_assertion_result(assertion)

          mfa ->
            args = required_values!(changes, prefix, assertion.requires)

            mfa
            |> invoke(repo, args)
            |> normalize_assertion_result(assertion)
        end
      end)
    end

    defp add_node(multi, _workflow, :task, task, opts) do
      cond do
        Map.get(task, :workflow) != nil ->
          add_workflow_task(multi, task, opts)

        Map.get(task, :call) != nil ->
          add_function_task(multi, task, opts)

        true ->
          Multi.error(
            multi,
            op_name(Keyword.get(opts, :prefix, []), {:invalid_task, task.name}),
            {:invalid_task, task.name, :missing_call_or_workflow}
          )
      end
    end

    defp add_node(multi, workflow, :decision, decision, opts) do
      prefix = Keyword.get(opts, :prefix, [])
      decision_op = op_name(prefix, decision.name)

      multi
      |> Multi.run(decision_op, fn repo, changes ->
        case decision.evaluated_by do
          {module, function, arg_spec} when is_list(arg_spec) ->
            invoke_with_spec({module, function, arg_spec}, repo, changes, prefix)
            |> normalize_decision_result(decision)

          mfa ->
            args = required_values!(changes, prefix, decision.requires)

            mfa
            |> invoke(repo, args)
            |> normalize_decision_result(decision)
        end
      end)
      |> Multi.merge(fn changes ->
        branch = Map.fetch!(changes, decision_op)
        target = Keyword.fetch!(decision.branches || [], branch)

        graph = Shigoto.Graph.workflow_graph(workflow)
        branch_vertices = reachable_vertices(graph, target)

        branch_outer_requires = collect_branch_outer_requires(workflow, branch_vertices)

        branch_multi =
          Enum.reduce(branch_outer_requires, Multi.new(), fn req, m ->
            Multi.put(m, op_name(prefix, req), get_value!(changes, prefix, req))
          end)

        compile_region(branch_multi, workflow, branch_vertices, opts)
      end)
    end

    defp add_node(multi, _workflow, :emit, {emit, index}, opts) do
      prefix = Keyword.get(opts, :prefix, [])
      op = op_name(prefix, {:emit, emit.event, index})
      callback = Keyword.get(opts, :emit)

      Multi.run(multi, op, fn repo, changes ->
        payload = build_emit_payload!(changes, prefix, emit)
        event = normalize_local_event_ref(opts, emit.event)

        callback
        |> invoke_emit(repo, changes, event, payload, emit)
        |> normalize_run_result()
      end)
    end

    defp add_function_task(multi, task, opts) do
      prefix = Keyword.get(opts, :prefix, [])
      op = op_name(prefix, task.produces || task.name)

      Multi.run(multi, op, fn repo, changes ->
        case task.call do
          {module, function, arg_spec} when is_list(arg_spec) ->
            invoke_with_spec({module, function, arg_spec}, repo, changes, prefix)
            |> normalize_run_result()

          mfa ->
            args = required_values!(changes, prefix, task.requires)

            mfa
            |> invoke(repo, args)
            |> normalize_run_result()
        end
      end)
    end

    defp add_workflow_task(multi, task, opts) do
      prefix = Keyword.get(opts, :prefix, [])
      current_module = Keyword.get(opts, :module)
      resolver = Keyword.get(opts, :workflow_resolver, &default_workflow_resolver/2)

      produced_name = task.produces || task.name
      produced_op = op_name(prefix, produced_name)
      sub_prefix = prefix ++ [task.name]

      multi
      |> Multi.merge(fn changes ->
        {callee_module, callee_workflow} =
          resolve_workflow_call!(task.workflow, current_module, resolver)

        sub_inputs =
          task.requires
          |> list()
          |> Map.new(fn input_name ->
            {input_name, get_value!(changes, prefix, input_name)}
          end)

        from_workflow(
          callee_workflow,
          sub_inputs,
          opts
          |> Keyword.put(:module, callee_module)
          |> Keyword.put(:prefix, sub_prefix)
        )
      end)
      |> Multi.run(produced_op, fn _repo, changes ->
        {_callee_module, callee_workflow} =
          resolve_workflow_call!(task.workflow, current_module, resolver)

        {:ok, collect_sub_workflow_outputs(changes, sub_prefix, callee_workflow)}
      end)
    end

    defp put_inputs(multi, workflow, inputs, prefix) do
      workflow.inputs
      |> list()
      |> Enum.reduce(multi, fn input, multi ->
        case fetch_input(inputs, input.name) do
          {:ok, value} ->
            Multi.put(multi, op_name(prefix, input.name), value)

          :error ->
            if Map.get(input, :required?, true) do
              Multi.error(
                multi,
                op_name(prefix, {:missing_input, input.name}),
                {:missing_input, workflow.name, input.name}
              )
            else
              multi
            end
        end
      end)
    end

    defp all_vertices(workflow) do
      workflow
      |> Shigoto.Graph.workflow_graph()
      |> Map.fetch!(:vertices)
    end

    defp node_index(workflow) do
      assertions =
        workflow.assertions
        |> list()
        |> Map.new(fn assertion ->
          {assertion.name, {:assert, assertion}}
        end)

      tasks =
        workflow.tasks
        |> list()
        |> Map.new(fn task ->
          {task.name, {:task, task}}
        end)

      decisions =
        workflow.decisions
        |> list()
        |> Map.new(fn decision ->
          {decision.name, {:decision, decision}}
        end)

      emits =
        workflow.emits
        |> list()
        |> Enum.with_index()
        |> Map.new(fn {emit, index} ->
          {{:emit, workflow.name, emit.event, index}, {:emit, {emit, index}}}
        end)

      assertions
      |> Map.merge(tasks)
      |> Map.merge(decisions)
      |> Map.merge(emits)
    end

    defp branch_descendants_for_decisions(workflow, graph, region_vertices) do
      workflow.decisions
      |> list()
      |> Enum.filter(fn decision ->
        MapSet.member?(region_vertices, decision.name)
      end)
      |> Enum.reduce(MapSet.new(), fn decision, acc ->
        decision.branches
        |> list()
        |> Enum.reduce(acc, fn {_branch, target}, acc ->
          MapSet.union(acc, reachable_vertices(graph, target))
        end)
      end)
    end

    defp reachable_vertices(%Shigoto.Graph{} = graph, start_vertex) do
      successors = successors_by_vertex(graph)

      do_reachable([start_vertex], successors, MapSet.new())
    end

    defp do_reachable([], _successors, visited), do: visited

    defp do_reachable([vertex | rest], successors, visited) do
      if MapSet.member?(visited, vertex) do
        do_reachable(rest, successors, visited)
      else
        next_vertices = Map.get(successors, vertex, [])

        do_reachable(
          next_vertices ++ rest,
          successors,
          MapSet.put(visited, vertex)
        )
      end
    end

    defp successors_by_vertex(%Shigoto.Graph{} = graph) do
      Enum.reduce(graph.edges, %{}, fn edge, acc ->
        Map.update(acc, edge.from, [edge.to], fn existing ->
          [edge.to | existing]
        end)
      end)
    end

    defp fetch_workflow!(module, workflow_name) do
      module
      |> Shigoto.Info.workflows()
      |> Enum.find(&(&1.name == workflow_name))
      |> case do
        nil ->
          raise ArgumentError,
                "unknown Shigoto workflow #{inspect(workflow_name)} in #{inspect(module)}"

        workflow ->
          workflow
      end
    end

    defp fetch_automation!(module, automation_name) do
      module
      |> Shigoto.Info.automations()
      |> Enum.find(&(&1.name == automation_name))
      |> case do
        nil ->
          raise ArgumentError,
                "unknown Shigoto automation #{inspect(automation_name)} in #{inspect(module)}"

        automation ->
          automation
      end
    end

    defp default_workflow_resolver(module, workflow_name) do
      {module, fetch_workflow!(module, workflow_name)}
    end

    defp resolve_workflow_call!(workflow_name, current_module, resolver)
         when is_atom(workflow_name) do
      if is_nil(current_module) do
        raise ArgumentError,
              "cannot resolve local workflow #{inspect(workflow_name)} without :module option"
      end

      resolver.(current_module, workflow_name)
    end

    defp resolve_workflow_call!({module, workflow_name}, _current_module, resolver)
         when is_atom(module) and is_atom(workflow_name) do
      resolver.(module, workflow_name)
    end

    defp resolve_workflow_call!({module, workflow_name, _args}, _current_module, resolver)
         when is_atom(module) and is_atom(workflow_name) do
      resolver.(module, workflow_name)
    end

    defp resolve_workflow_call!(other, _current_module, _resolver) do
      raise ArgumentError,
            "invalid workflow call #{inspect(other)}. Expected :workflow_name or {Module, :workflow_name}"
    end

    defp required_values!(changes, prefix, requires) do
      requires
      |> list()
      |> Enum.map(fn value_name ->
        get_value!(changes, prefix, value_name)
      end)
    end

    defp get_value!(changes, prefix, value_name) when is_atom(value_name) do
      key = op_name(prefix, value_name)

      case Map.fetch(changes, key) do
        {:ok, value} ->
          value

        :error ->
          raise KeyError,
                "missing Shigoto value #{inspect(value_name)} under operation key #{inspect(key)}"
      end
    end

    defp build_emit_payload!(changes, prefix, emit) do
      emit.mappings
      |> list()
      |> Map.new(fn mapping ->
        target = mapping_target(mapping)
        value = resolve_source_path!(changes, prefix, mapping.from)

        {target, value}
      end)
    end

    defp resolve_source_path!(changes, prefix, [root | rest]) when is_atom(root) do
      changes
      |> get_value!(prefix, root)
      |> fetch_nested_path!(rest)
    end

    defp resolve_source_path!(_changes, _prefix, other) do
      raise ArgumentError,
            "invalid Shigoto mapping source #{inspect(other)}. Expected a non-empty atom path"
    end

    defp resolve_event_payload_path!(payload, [root | rest]) when is_atom(root) do
      payload
      |> fetch_key!(root)
      |> fetch_nested_path!(rest)
    end

    defp resolve_event_payload_path!(_payload, other) do
      raise ArgumentError,
            "invalid Shigoto automation mapping source #{inspect(other)}. Expected a non-empty atom path"
    end

    defp fetch_nested_path!(value, []), do: value

    defp fetch_nested_path!(value, [key | rest]) when is_atom(key) do
      value
      |> fetch_key!(key)
      |> fetch_nested_path!(rest)
    end

    defp fetch_key!(value, key) when is_map(value) do
      case Map.fetch(value, key) do
        {:ok, nested} ->
          nested

        :error ->
          string_key = Atom.to_string(key)

          case Map.fetch(value, string_key) do
            {:ok, nested} ->
              nested

            :error ->
              if is_struct(value) do
                raise KeyError,
                      "missing key #{inspect(key)} in struct #{inspect(value.__struct__)}"
              else
                raise KeyError,
                      "missing key #{inspect(key)} in map #{inspect(value)}"
              end
          end
      end
    end

    defp fetch_key!(value, key) when is_list(value) do
      if Keyword.keyword?(value) do
        case Keyword.fetch(value, key) do
          {:ok, nested} ->
            nested

          :error ->
            raise KeyError,
                  "missing key #{inspect(key)} in keyword list #{inspect(value)}"
        end
      else
        raise ArgumentError,
              "cannot fetch key #{inspect(key)} from non-keyword list #{inspect(value)}"
      end
    end

    defp fetch_key!(value, key) do
      raise ArgumentError,
            "cannot fetch key #{inspect(key)} from #{inspect(value)}"
    end

    defp invoke({module, function, arity}, repo, args)
         when is_atom(module) and is_atom(function) and is_integer(arity) and arity >= 0 do
      cond do
        arity == length(args) ->
          apply(module, function, args)

        arity == length(args) + 1 ->
          apply(module, function, [repo | args])

        true ->
          raise ArgumentError,
                "cannot invoke #{inspect(module)}.#{function}/#{arity} with #{length(args)} required values"
      end
    end

    defp invoke(other, _repo, _args) do
      raise ArgumentError,
            "invalid Shigoto MFA #{inspect(other)}. Expected {Module, function, arity}"
    end

    defp invoke_with_spec({module, function, arg_spec}, repo, changes, prefix)
         when is_atom(module) and is_atom(function) and is_list(arg_spec) do
      args =
        Enum.map(arg_spec, fn
          :repo -> repo
          name when is_atom(name) -> get_value!(changes, prefix, name)
        end)

      apply(module, function, args)
    end

    defp invoke_emit(nil, _repo, _changes, _event, payload, _emit) do
      {:ok, payload}
    end

    defp invoke_emit(callback, repo, changes, event, payload, emit)
         when is_function(callback) do
      case fun_arity(callback) do
        1 -> callback.(payload)
        2 -> callback.(event, payload)
        3 -> callback.(repo, event, payload)
        4 -> callback.(repo, changes, event, payload)
        5 -> callback.(repo, changes, event, payload, emit)
        arity -> raise ArgumentError, "invalid Shigoto emit callback arity #{arity}"
      end
    end

    defp invoke_emit({module, function, args}, repo, changes, event, payload, _emit)
         when is_atom(module) and is_atom(function) and is_list(args) do
      apply(module, function, [repo, changes, event, payload | args])
    end

    defp invoke_emit({module, function, arity}, repo, changes, event, payload, emit)
         when is_atom(module) and is_atom(function) and is_integer(arity) and arity >= 0 do
      case arity do
        1 -> apply(module, function, [payload])
        2 -> apply(module, function, [event, payload])
        3 -> apply(module, function, [repo, event, payload])
        4 -> apply(module, function, [repo, changes, event, payload])
        5 -> apply(module, function, [repo, changes, event, payload, emit])
        _ -> raise ArgumentError, "invalid Shigoto emit MFA arity #{arity}"
      end
    end

    defp invoke_emit(other, _repo, _changes, _event, _payload, _emit) do
      raise ArgumentError,
            "invalid Shigoto emit callback #{inspect(other)}"
    end

    defp normalize_assertion_result({:ok, true}, _assertion), do: {:ok, true}

    defp normalize_assertion_result({:ok, false}, assertion) do
      {:error, {:assertion_failed, assertion.name}}
    end

    defp normalize_assertion_result({:error, _reason} = error, _assertion), do: error
    defp normalize_assertion_result(true, _assertion), do: {:ok, true}

    defp normalize_assertion_result(false, assertion) do
      {:error, {:assertion_failed, assertion.name}}
    end

    defp normalize_assertion_result(other, assertion) do
      if other do
        {:ok, other}
      else
        {:error, {:assertion_failed, assertion.name}}
      end
    end

    defp normalize_decision_result({:ok, branch}, decision) do
      normalize_decision_branch(branch, decision)
    end

    defp normalize_decision_result({:error, _reason} = error, _decision), do: error

    defp normalize_decision_result(branch, decision) do
      normalize_decision_branch(branch, decision)
    end

    defp normalize_decision_branch(branch, decision) do
      if Keyword.has_key?(decision.branches || [], branch) do
        {:ok, branch}
      else
        {:error, {:unknown_decision_branch, decision.name, branch}}
      end
    end

    defp normalize_run_result({:ok, _value} = ok), do: ok
    defp normalize_run_result({:error, _reason} = error), do: error
    defp normalize_run_result(value), do: {:ok, value}

    defp normalize_local_event_ref(opts, event_name) do
      case Keyword.get(opts, :module) do
        nil -> event_name
        module -> {module, event_name}
      end
    end

    defp collect_sub_workflow_outputs(changes, prefix, workflow) do
      input_pairs =
        Enum.map(list(workflow.inputs), fn inp -> {inp.name, op_name(prefix, inp.name)} end)

      assertion_pairs =
        Enum.map(list(workflow.assertions), fn a ->
          {{:assert, a.name}, op_name(prefix, {:assert, a.name})}
        end)

      task_pairs =
        Enum.map(list(workflow.tasks), fn t ->
          n = t.produces || t.name
          {n, op_name(prefix, n)}
        end)

      decision_pairs =
        Enum.map(list(workflow.decisions), fn d -> {d.name, op_name(prefix, d.name)} end)

      (input_pairs ++ assertion_pairs ++ task_pairs ++ decision_pairs)
      |> Enum.reduce(%{}, fn {logical, key}, acc ->
        case Map.fetch(changes, key) do
          {:ok, value} -> Map.put(acc, logical, value)
          :error -> acc
        end
      end)
    end

    defp collect_branch_outer_requires(workflow, branch_vertices) do
      branch_produces =
        workflow.tasks
        |> list()
        |> Enum.filter(&MapSet.member?(branch_vertices, &1.name))
        |> Enum.map(& &1.produces)
        |> Enum.reject(&is_nil/1)
        |> MapSet.new()

      input_names =
        workflow.inputs
        |> list()
        |> Enum.map(& &1.name)
        |> MapSet.new()

      branch_nodes =
        (list(workflow.tasks) ++ list(workflow.assertions) ++ list(workflow.decisions))
        |> Enum.filter(&MapSet.member?(branch_vertices, &1.name))

      branch_nodes
      |> Enum.flat_map(&list(&1.requires))
      |> Enum.uniq()
      |> Enum.reject(fn req ->
        MapSet.member?(branch_produces, req) or MapSet.member?(input_names, req)
      end)
    end

    defp op_name([], logical_name), do: logical_name
    defp op_name(prefix, logical_name), do: {:shigoto, prefix, logical_name}

    defp fetch_input(inputs, name) when is_map(inputs) do
      case Map.fetch(inputs, name) do
        {:ok, value} ->
          {:ok, value}

        :error ->
          Map.fetch(inputs, Atom.to_string(name))
      end
    end

    defp fetch_input(inputs, name) when is_list(inputs) do
      Keyword.fetch(inputs, name)
    end

    defp mapping_target(mapping) do
      cond do
        Map.has_key?(mapping, :target) -> mapping.target
        Map.has_key?(mapping, :input) -> mapping.input
        true -> raise ArgumentError, "invalid Shigoto mapping #{inspect(mapping)}"
      end
    end

    defp fun_arity(fun) do
      {:arity, arity} = :erlang.fun_info(fun, :arity)
      arity
    end

    defp list(nil), do: []
    defp list(value) when is_list(value), do: value
    defp list(value), do: [value]
  end
end
