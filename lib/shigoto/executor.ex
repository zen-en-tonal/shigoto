if Code.ensure_loaded?(Ecto.Multi) do
  defmodule Shigoto.Executor do
    @moduledoc """
    Eager workflow executor.

    Evaluates all workflow nodes as plain function calls outside any DB
    transaction. `persists` changesets (including those from nested
    sub-workflows) are accumulated into an `Ecto.Multi` that is returned to
    the caller. Emit payloads are similarly returned as a list — the caller
    decides when and how to dispatch them.

    ## Usage

        {:ok, context, persist_multi, emits} =
          Shigoto.Executor.run(MyWorkflows, :approve_order, inputs, repo: MyRepo)

        {:ok, _results} = MyRepo.transaction(persist_multi)
        Enum.each(emits, fn {event, payload} -> MyApp.Events.publish(event, payload) end)

    ## Outbox pattern

    Because emits are returned alongside the persist multi, you can add them to
    the same DB transaction:

        {:ok, _ctx, persist_multi, emits} = Executor.run(...)

        outbox_multi =
          Enum.reduce(emits, persist_multi, fn {event, payload}, m ->
            cs = OutboxEntry.changeset(%OutboxEntry{}, %{event: inspect(event), payload: payload})
            Ecto.Multi.insert(m, {:outbox, event}, cs)
          end)

        {:ok, _} = MyRepo.transaction(outbox_multi)

    ## Return values

      * `{:ok, context, persist_multi, emits}` — all nodes succeeded.
        `persist_multi` is an `Ecto.Multi` ready for `Repo.transaction/2`
        (empty when no `persists` are declared). `emits` is a list of
        `{event_ref, payload}` tuples in topological order.
      * `{:error, reason, partial_context, partial_emits}` — a node failed.
        `partial_emits` contains payloads for any emit nodes that were reached
        before the failure (their `after_node` sources had already succeeded).

    ## Error reasons

      * `{:assertion_failed, name}` — assertion returned false/nil
      * `{:task_failed, name, reason}` — task returned `{:error, reason}`
      * `{:task_raised, name, exception}` — task raised an exception
      * `{:unknown_branch, name, branch}` — decision returned an undeclared branch
    """

    alias Ecto.Multi

    @type context :: %{optional(atom()) => term()}
    @type inputs :: map() | keyword()
    @type workflow_name :: atom()

    @type emit_result :: {atom() | {module(), atom()}, map()}

    @type reason ::
            {:assertion_failed, atom()}
            | {:task_failed, atom(), term()}
            | {:task_raised, atom(), Exception.t()}
            | {:unknown_branch, atom(), atom()}

    @doc """
    Runs a named workflow and returns the execution context plus a persist Multi.
    """
    @spec run(module(), workflow_name(), inputs(), keyword()) ::
            {:ok, context(), Ecto.Multi.t(), [emit_result()]}
            | {:error, reason(), context(), [emit_result()]}
    def run(module, workflow_name, inputs \\ %{}, opts \\ []) do
      workflow = fetch_workflow!(module, workflow_name)
      opts = Keyword.put_new(opts, :module, module)
      run_workflow(workflow, inputs, opts)
    end

    @doc """
    Runs a workflow via an automation.

    Maps the event payload to workflow inputs using the automation's `map`
    declarations, then delegates to `run_workflow/3`.
    """
    @spec run_automation(module(), atom(), map() | keyword(), keyword()) ::
            {:ok, context(), Ecto.Multi.t(), [emit_result()]}
            | {:error, reason(), context(), [emit_result()]}
    def run_automation(module, automation_name, event_payload, opts \\ []) do
      automation = fetch_automation!(module, automation_name)
      workflow = fetch_workflow!(module, automation.run)

      inputs =
        automation.mappings
        |> list()
        |> Map.new(fn mapping ->
          {mapping_target(mapping), resolve_event_payload_path!(event_payload, mapping.from)}
        end)

      opts = Keyword.put_new(opts, :module, module)
      run_workflow(workflow, inputs, opts)
    end

    @doc """
    Runs a workflow struct directly.
    """
    @spec run_workflow(struct(), inputs(), keyword()) ::
            {:ok, context(), Ecto.Multi.t(), [emit_result()]}
            | {:error, reason(), context(), [emit_result()]}
    def run_workflow(workflow, inputs \\ %{}, opts \\ []) do
      context = seed_inputs!(workflow, inputs)
      execute_region(workflow, context, Multi.new(), opts)
    end

    # -------------------------------------------------------------------------
    # Core execution engine
    # -------------------------------------------------------------------------

    defp execute_region(workflow, context, persist_multi, opts) do
      graph = Shigoto.Graph.workflow_graph(workflow)

      {:ok, topsort} =
        Shigoto.Graph.validate_acyclic(graph, "workflow #{inspect(workflow.name)}")

      node_index = build_node_index(workflow)
      persists_set = workflow.persists |> list() |> MapSet.new()

      # State: {context, skip_set, persist_multi, deferred_emit_list}
      initial = {:ok, {context, MapSet.new(), persist_multi, []}}

      final =
        Enum.reduce_while(topsort, initial, fn vertex, {:ok, {ctx, skip, multi, emits}} ->
          if MapSet.member?(skip, vertex) do
            {:cont, {:ok, {ctx, skip, multi, emits}}}
          else
            case Map.fetch(node_index, vertex) do
              {:ok, {kind, node}} ->
                case execute_node(kind, node, workflow, ctx, skip, multi, emits, persists_set, graph, opts) do
                  {:ok, new_state} -> {:cont, {:ok, new_state}}
                  {:error, _, _, _} = err -> {:halt, err}
                end

              :error ->
                {:cont, {:ok, {ctx, skip, multi, emits}}}
            end
          end
        end)

      case final do
        {:ok, {final_ctx, _skip, final_multi, emit_jobs}} ->
          built = build_emits(Enum.reverse(emit_jobs), final_ctx, opts)
          {:ok, final_ctx, final_multi, built}

        {:error, reason, partial_ctx, partial_emit_jobs} ->
          built = build_emits(Enum.reverse(partial_emit_jobs), partial_ctx, opts)
          {:error, reason, partial_ctx, built}
      end
    end

    # -------------------------------------------------------------------------
    # Node dispatch
    # -------------------------------------------------------------------------

    defp execute_node(:assert, assertion, _workflow, ctx, skip, multi, emits, _persists, _graph, opts) do
      repo = Keyword.get(opts, :repo)

      result =
        case assertion.evaluated_by do
          {m, f, args} when is_list(args) ->
            invoke_with_spec({m, f, args}, repo, ctx)

          mfa ->
            required_vals = list(assertion.requires) |> Enum.map(&Map.fetch!(ctx, &1))
            invoke(mfa, repo, required_vals)
        end

      case normalize_assertion_result(result, assertion) do
        {:ok, _} ->
          {:ok, {Map.put(ctx, {:assert, assertion.name}, true), skip, multi, emits}}

        {:error, reason} ->
          {:error, reason, ctx, emits}
      end
    end

    defp execute_node(:task, task, workflow, ctx, skip, multi, emits, persists, graph, opts) do
      if Map.get(task, :workflow) != nil do
        execute_workflow_task(task, workflow, ctx, skip, multi, emits, persists, graph, opts)
      else
        execute_function_task(task, ctx, skip, multi, emits, persists, opts)
      end
    end

    defp execute_node(:decision, decision, _workflow, ctx, skip, multi, emits, _persists, graph, opts) do
      repo = Keyword.get(opts, :repo)

      result =
        case decision.evaluated_by do
          {m, f, args} when is_list(args) ->
            invoke_with_spec({m, f, args}, repo, ctx)

          mfa ->
            required_vals = list(decision.requires) |> Enum.map(&Map.fetch!(ctx, &1))
            invoke(mfa, repo, required_vals)
        end

      case normalize_decision_result(result, decision) do
        {:ok, branch} ->
          taken_target = Keyword.fetch!(decision.branches, branch)

          new_skip =
            decision.branches
            |> Keyword.values()
            |> Enum.reject(&(&1 == taken_target))
            |> Enum.flat_map(&reachable_vertices(graph, &1))
            |> MapSet.new()
            |> MapSet.union(skip)

          {:ok, {Map.put(ctx, decision.name, branch), new_skip, multi, emits}}

        {:error, reason} ->
          {:error, reason, ctx, emits}
      end
    end

    defp execute_node(:emit, {emit, _index}, _workflow, ctx, skip, multi, emits, _persists, _graph, _opts) do
      {:ok, {ctx, skip, multi, [emit | emits]}}
    end

    # -------------------------------------------------------------------------
    # Function task
    # -------------------------------------------------------------------------

    defp execute_function_task(task, ctx, skip, multi, emits, persists, opts) do
      repo = Keyword.get(opts, :repo)
      produce_key = task.produces || task.name

      raw =
        try do
          case task.call do
            {m, f, args} when is_list(args) ->
              invoke_with_spec({m, f, args}, repo, ctx)

            mfa ->
              required_vals = list(task.requires) |> Enum.map(&Map.fetch!(ctx, &1))
              invoke(mfa, repo, required_vals)
          end
        rescue
          e -> {:__raised__, task.name, e}
        end

      case raw do
        {:__raised__, name, exception} ->
          {:error, {:task_raised, name, exception}, ctx, emits}

        other ->
          case normalize_run_result(other) do
            {:ok, value} ->
              new_ctx = Map.put(ctx, produce_key, value)

              new_multi =
                if MapSet.member?(persists, produce_key) do
                  append_changeset_to_multi(multi, produce_key, value)
                else
                  multi
                end

              {:ok, {new_ctx, skip, new_multi, emits}}

            {:error, reason} ->
              {:error, {:task_failed, task.name, reason}, ctx, emits}
          end
      end
    end

    # -------------------------------------------------------------------------
    # Sub-workflow task
    # -------------------------------------------------------------------------

    defp execute_workflow_task(task, _workflow, ctx, skip, multi, emits, _persists, _graph, opts) do
      produce_key = task.produces || task.name
      current_module = Keyword.get(opts, :module)
      resolver = Keyword.get(opts, :workflow_resolver, &default_workflow_resolver/2)

      {callee_module, callee_workflow} =
        resolve_workflow_call!(task.workflow, current_module, resolver)

      sub_inputs =
        task.requires
        |> list()
        |> Map.new(fn name -> {name, Map.fetch!(ctx, name)} end)

      sub_opts = Keyword.put(opts, :module, callee_module)

      case run_workflow(callee_workflow, sub_inputs, sub_opts) do
        {:ok, sub_ctx, sub_multi, sub_emits} ->
          new_ctx = Map.put(ctx, produce_key, sub_ctx)
          new_multi = Multi.merge(multi, fn _ -> sub_multi end)
          {:ok, {new_ctx, skip, new_multi, emits ++ sub_emits}}

        {:error, reason, sub_ctx, sub_partial_emits} ->
          {:error, reason, Map.put(ctx, produce_key, sub_ctx), emits ++ sub_partial_emits}
      end
    end

    # -------------------------------------------------------------------------
    # Emit payload builder
    # -------------------------------------------------------------------------

    defp build_emits(emit_jobs, ctx, opts) do
      Enum.map(emit_jobs, fn emit ->
        event = normalize_local_event_ref(opts, emit.event)
        payload = build_emit_payload!(ctx, emit)
        {event, payload}
      end)
    end

    # -------------------------------------------------------------------------
    # Persist Multi accumulation
    # -------------------------------------------------------------------------

    defp append_changeset_to_multi(multi, _op, entries)
         when is_map(entries) and not is_struct(entries) do
      Enum.reduce(entries, multi, fn {name, entry}, m ->
        append_changeset_to_multi(m, name, entry)
      end)
    end

    defp append_changeset_to_multi(multi, op, entries) when is_list(entries) do
      entries
      |> Enum.with_index()
      |> Enum.reduce(multi, fn {entry, idx}, m ->
        append_changeset_to_multi(m, {op, idx}, entry)
      end)
    end

    defp append_changeset_to_multi(multi, op, %Ecto.Changeset{data: %_{__meta__: %{state: :built}}} = cs) do
      Multi.insert(multi, op, cs)
    end

    defp append_changeset_to_multi(multi, op, %Ecto.Changeset{} = cs) do
      Multi.update(multi, op, cs)
    end

    defp append_changeset_to_multi(multi, _op, _other), do: multi

    # -------------------------------------------------------------------------
    # Context seeding
    # -------------------------------------------------------------------------

    defp seed_inputs!(workflow, inputs) do
      workflow.inputs
      |> list()
      |> Enum.reduce(%{}, fn input, ctx ->
        case fetch_input(inputs, input.name) do
          {:ok, value} ->
            Map.put(ctx, input.name, value)

          :error ->
            if Map.get(input, :required?, true) do
              raise ArgumentError,
                    "missing required input #{inspect(input.name)} for workflow #{inspect(workflow.name)}"
            else
              ctx
            end
        end
      end)
    end

    # -------------------------------------------------------------------------
    # Node index
    # -------------------------------------------------------------------------

    defp build_node_index(workflow) do
      assertions =
        workflow.assertions |> list() |> Map.new(&{&1.name, {:assert, &1}})

      tasks =
        workflow.tasks |> list() |> Map.new(&{&1.name, {:task, &1}})

      decisions =
        workflow.decisions |> list() |> Map.new(&{&1.name, {:decision, &1}})

      emits =
        workflow.emits
        |> list()
        |> Enum.with_index()
        |> Map.new(fn {emit, index} ->
          {{:emit, workflow.name, emit.event, index}, {:emit, {emit, index}}}
        end)

      assertions |> Map.merge(tasks) |> Map.merge(decisions) |> Map.merge(emits)
    end

    # -------------------------------------------------------------------------
    # Graph traversal — BFS over Shigoto.Graph edges
    # -------------------------------------------------------------------------

    defp reachable_vertices(%Shigoto.Graph{} = graph, start) do
      successors = successors_by_vertex(graph)
      do_reachable([start], successors, MapSet.new())
    end

    defp do_reachable([], _s, visited), do: visited

    defp do_reachable([v | rest], successors, visited) do
      if MapSet.member?(visited, v) do
        do_reachable(rest, successors, visited)
      else
        nexts = Map.get(successors, v, [])
        do_reachable(nexts ++ rest, successors, MapSet.put(visited, v))
      end
    end

    defp successors_by_vertex(%Shigoto.Graph{} = graph) do
      Enum.reduce(graph.edges, %{}, fn edge, acc ->
        Map.update(acc, edge.from, [edge.to], &[edge.to | &1])
      end)
    end

    # -------------------------------------------------------------------------
    # Workflow / automation lookup
    # -------------------------------------------------------------------------

    defp fetch_workflow!(module, workflow_name) do
      module
      |> Shigoto.Info.workflows()
      |> Enum.find(&(&1.name == workflow_name))
      |> case do
        nil ->
          raise ArgumentError,
                "unknown Shigoto workflow #{inspect(workflow_name)} in #{inspect(module)}"

        wf ->
          wf
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

        a ->
          a
      end
    end

    defp default_workflow_resolver(module, workflow_name) do
      {module, fetch_workflow!(module, workflow_name)}
    end

    defp resolve_workflow_call!(name, current_module, resolver) when is_atom(name) do
      if is_nil(current_module) do
        raise ArgumentError,
              "cannot resolve local workflow #{inspect(name)} without :module option"
      end

      resolver.(current_module, name)
    end

    defp resolve_workflow_call!({module, name}, _current, resolver)
         when is_atom(module) and is_atom(name) do
      resolver.(module, name)
    end

    defp resolve_workflow_call!({module, name, _args}, _current, resolver)
         when is_atom(module) and is_atom(name) do
      resolver.(module, name)
    end

    defp resolve_workflow_call!(other, _current, _resolver) do
      raise ArgumentError,
            "invalid workflow call #{inspect(other)}. Expected :name or {Module, :name}"
    end

    # -------------------------------------------------------------------------
    # MFA invocation
    # -------------------------------------------------------------------------

    defp invoke({module, function, arity}, repo, args)
         when is_atom(module) and is_atom(function) and is_integer(arity) do
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

    defp invoke_with_spec({module, function, arg_spec}, repo, context)
         when is_atom(module) and is_atom(function) and is_list(arg_spec) do
      args =
        Enum.map(arg_spec, fn
          :repo -> repo
          name when is_atom(name) -> Map.fetch!(context, name)
        end)

      apply(module, function, args)
    end

    # -------------------------------------------------------------------------
    # Emit payload building
    # -------------------------------------------------------------------------

    defp build_emit_payload!(ctx, emit) do
      emit.mappings
      |> list()
      |> Map.new(fn mapping ->
        target = mapping_target(mapping)
        value = resolve_source_path!(ctx, mapping.from)
        {target, value}
      end)
    end

    defp resolve_source_path!(ctx, [root | rest]) when is_atom(root) do
      ctx |> Map.fetch!(root) |> fetch_nested_path!(rest)
    end

    defp resolve_source_path!(_ctx, other) do
      raise ArgumentError,
            "invalid Shigoto mapping source #{inspect(other)}. Expected a non-empty atom path"
    end

    defp resolve_event_payload_path!(payload, [root | rest]) when is_atom(root) do
      payload |> fetch_key!(root) |> fetch_nested_path!(rest)
    end

    defp resolve_event_payload_path!(_payload, other) do
      raise ArgumentError,
            "invalid Shigoto automation mapping source #{inspect(other)}. Expected a non-empty atom path"
    end

    defp fetch_nested_path!(value, []), do: value

    defp fetch_nested_path!(value, [key | rest]) when is_atom(key) do
      value |> fetch_key!(key) |> fetch_nested_path!(rest)
    end

    defp fetch_key!(value, key) when is_map(value) do
      case Map.fetch(value, key) do
        {:ok, v} ->
          v

        :error ->
          sk = Atom.to_string(key)

          case Map.fetch(value, sk) do
            {:ok, v} ->
              v

            :error ->
              if is_struct(value) do
                raise KeyError,
                      "missing key #{inspect(key)} in struct #{inspect(value.__struct__)}"
              else
                raise KeyError, "missing key #{inspect(key)} in map #{inspect(value)}"
              end
          end
      end
    end

    defp fetch_key!(value, key) when is_list(value) do
      if Keyword.keyword?(value) do
        case Keyword.fetch(value, key) do
          {:ok, v} -> v
          :error -> raise KeyError, "missing key #{inspect(key)} in keyword list #{inspect(value)}"
        end
      else
        raise ArgumentError, "cannot fetch key #{inspect(key)} from non-keyword list #{inspect(value)}"
      end
    end

    defp fetch_key!(value, key) do
      raise ArgumentError, "cannot fetch key #{inspect(key)} from #{inspect(value)}"
    end

    # -------------------------------------------------------------------------
    # Result normalization
    # -------------------------------------------------------------------------

    defp normalize_assertion_result({:ok, true}, _a), do: {:ok, true}
    defp normalize_assertion_result({:ok, false}, a), do: {:error, {:assertion_failed, a.name}}
    defp normalize_assertion_result({:error, _} = e, _a), do: e
    defp normalize_assertion_result(true, _a), do: {:ok, true}
    defp normalize_assertion_result(false, a), do: {:error, {:assertion_failed, a.name}}

    defp normalize_assertion_result(other, a) do
      if other, do: {:ok, other}, else: {:error, {:assertion_failed, a.name}}
    end

    defp normalize_decision_result({:ok, branch}, d), do: normalize_decision_branch(branch, d)
    defp normalize_decision_result({:error, _} = e, _d), do: e
    defp normalize_decision_result(branch, d), do: normalize_decision_branch(branch, d)

    defp normalize_decision_branch(branch, decision) do
      if Keyword.has_key?(decision.branches || [], branch) do
        {:ok, branch}
      else
        {:error, {:unknown_branch, decision.name, branch}}
      end
    end

    defp normalize_run_result({:ok, _} = ok), do: ok
    defp normalize_run_result({:error, _} = e), do: e
    defp normalize_run_result(v), do: {:ok, v}

    defp normalize_local_event_ref(opts, event_name) do
      case Keyword.get(opts, :module) do
        nil -> event_name
        m -> {m, event_name}
      end
    end

    # -------------------------------------------------------------------------
    # Misc helpers
    # -------------------------------------------------------------------------

    defp mapping_target(mapping) do
      cond do
        Map.has_key?(mapping, :target) -> mapping.target
        Map.has_key?(mapping, :input) -> mapping.input
        true -> raise ArgumentError, "invalid Shigoto mapping #{inspect(mapping)}"
      end
    end

    defp fetch_input(inputs, name) when is_map(inputs) do
      case Map.fetch(inputs, name) do
        {:ok, _} = ok -> ok
        :error -> Map.fetch(inputs, Atom.to_string(name))
      end
    end

    defp fetch_input(inputs, name) when is_list(inputs), do: Keyword.fetch(inputs, name)

    defp list(nil), do: []
    defp list(v) when is_list(v), do: v
    defp list(v), do: [v]
  end
end
