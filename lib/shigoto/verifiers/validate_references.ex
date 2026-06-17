defmodule Shigoto.Verifiers.ValidateReferences do
  use Spark.Dsl.Verifier

  def verify(dsl_state) do
    events = Shigoto.Info.events(dsl_state)
    workflows = Shigoto.Info.workflows(dsl_state)
    automations = Shigoto.Info.automations(dsl_state)

    events_by_name = Map.new(events, &{&1.name, &1})
    workflows_by_name = Map.new(workflows, &{&1.name, &1})

    with :ok <- validate_workflows(workflows, events_by_name),
         :ok <- validate_automations(automations, events_by_name, workflows_by_name) do
      :ok
    end
  end

  defp validate_workflows(workflows, events_by_name) do
    each(workflows, fn workflow ->
      with :ok <- validate_unique_node_names(workflow),
           :ok <- validate_unique_produced_values(workflow),
           :ok <- validate_required_values(workflow),
           :ok <- validate_after_refs(workflow),
           :ok <- validate_decision_branches(workflow),
           :ok <- validate_workflow_emits(workflow, events_by_name),
           :ok <- validate_cross_module_workflow_calls(workflow) do
        :ok
      end
    end)
  end

  defp validate_automations(automations, events_by_name, workflows_by_name) do
    each(automations, fn automation ->
      with {:ok, event} <- resolve_trigger_event(automation.on, events_by_name),
           {:ok, workflow} <- fetch_workflow(automation.run, workflows_by_name, automation),
           :ok <- validate_automation_mappings(automation, workflow),
           :ok <- validate_automation_event_refs(automation, event) do
        :ok
      end
    end)
  end

  defp validate_unique_node_names(workflow) do
    names =
      []
      |> Kernel.++(Enum.map(workflow.assertions || [], & &1.name))
      |> Kernel.++(Enum.map(workflow.tasks || [], & &1.name))
      |> Kernel.++(Enum.map(workflow.decisions || [], & &1.name))

    case duplicates(names) do
      [] ->
        :ok

      duplicated ->
        error("Duplicate node names #{inspect(duplicated)} in workflow #{inspect(workflow.name)}")
    end
  end

  defp validate_unique_produced_values(workflow) do
    produced_values =
      workflow.tasks
      |> List.wrap()
      |> Enum.map(& &1.produces)
      |> Enum.reject(&is_nil/1)

    case duplicates(produced_values) do
      [] ->
        :ok

      duplicated ->
        error(
          "Duplicate produced values #{inspect(duplicated)} in workflow #{inspect(workflow.name)}"
        )
    end
  end

  defp validate_required_values(workflow) do
    graph = Shigoto.Graph.workflow_graph(workflow)

    input_names =
      workflow.inputs
      |> List.wrap()
      |> Enum.map(& &1.name)
      |> MapSet.new()

    tasks_by_name =
      workflow.tasks
      |> List.wrap()
      |> Map.new(& {&1.name, &1})

    nodes =
      []
      |> Kernel.++(tag_nodes(:assert, workflow.assertions || []))
      |> Kernel.++(tag_nodes(:task, workflow.tasks || []))
      |> Kernel.++(tag_nodes(:decision, workflow.decisions || []))

    Shigoto.Graph.with_digraph(graph, fn digraph ->
      each(nodes, fn {kind, node} ->
        ancestors = :digraph_utils.reaching([node.name], digraph) |> MapSet.new()

        ancestor_produces =
          ancestors
          |> Enum.flat_map(fn ancestor_name ->
            case Map.fetch(tasks_by_name, ancestor_name) do
              {:ok, task} when not is_nil(task.produces) -> [task.produces]
              _ -> []
            end
          end)
          |> MapSet.new()

        available = MapSet.union(input_names, ancestor_produces)

        missing =
          node
          |> Map.get(:requires, [])
          |> List.wrap()
          |> Enum.reject(&MapSet.member?(available, &1))

        case missing do
          [] ->
            :ok

          _ ->
            error(
              "#{kind} #{inspect(node.name)} in workflow #{inspect(workflow.name)} requires unavailable values #{inspect(missing)}"
            )
        end
      end)
    end)
  end

  defp validate_after_refs(workflow) do
    node_names = node_names(workflow)

    nodes =
      []
      |> Kernel.++(tag_nodes(:task, workflow.tasks || []))
      |> Kernel.++(tag_nodes(:emit, workflow.emits || []))

    each(nodes, fn
      {:task, task} ->
        validate_after_values(
          task.after_nodes || [],
          node_names,
          "task #{inspect(task.name)}",
          workflow
        )

      {:emit, emit} ->
        validate_after_values(
          emit.after_nodes || [],
          node_names,
          "emit #{inspect(emit.event)}",
          workflow
        )
    end)
  end

  defp validate_after_values(after_values, node_names, subject, workflow) do
    missing =
      after_values
      |> Enum.reject(&MapSet.member?(node_names, &1))

    case missing do
      [] ->
        :ok

      _ ->
        error(
          "#{subject} in workflow #{inspect(workflow.name)} references unknown predecessor nodes #{inspect(missing)}"
        )
    end
  end

  defp validate_decision_branches(workflow) do
    node_names = node_names(workflow)

    each(workflow.decisions || [], fn decision ->
      unless Keyword.keyword?(decision.branches) do
        error(
          "decision #{inspect(decision.name)} in workflow #{inspect(workflow.name)} must have keyword-list branches"
        )
      else
        each(decision.branches, fn {branch_name, target} ->
          cond do
            not is_atom(branch_name) ->
              error(
                "decision #{inspect(decision.name)} in workflow #{inspect(workflow.name)} has non-atom branch #{inspect(branch_name)}"
              )

            not is_atom(target) ->
              error(
                "decision #{inspect(decision.name)} in workflow #{inspect(workflow.name)} branch #{inspect(branch_name)} points to non-atom target #{inspect(target)}"
              )

            not MapSet.member?(node_names, target) ->
              error(
                "decision #{inspect(decision.name)} in workflow #{inspect(workflow.name)} branch #{inspect(branch_name)} points to unknown node #{inspect(target)}"
              )

            true ->
              :ok
          end
        end)
      end
    end)
  end

  defp validate_workflow_emits(workflow, events_by_name) do
    available_values = flat_available_values(workflow)

    each(workflow.emits || [], fn emit ->
      case Map.fetch(events_by_name, emit.event) do
        {:ok, event} ->
          with :ok <- validate_emit_mappings(workflow, emit, event),
               :ok <- validate_emit_sources(workflow, emit, available_values) do
            :ok
          end

        :error ->
          error(
            "Unknown emitted event #{inspect(emit.event)} in workflow #{inspect(workflow.name)}"
          )
      end
    end)
  end

  defp validate_emit_mappings(workflow, emit, event) do
    field_names = event_field_names(event)

    each(emit.mappings || [], fn mapping ->
      target = mapping_target(mapping)

      if MapSet.member?(field_names, target) do
        :ok
      else
        error(
          "emit #{inspect(emit.event)} in workflow #{inspect(workflow.name)} maps unknown event payload field #{inspect(target)}"
        )
      end
    end)
  end

  defp validate_emit_sources(workflow, emit, available_values) do
    each(emit.mappings || [], fn mapping ->
      case source_root(mapping.from) do
        {:ok, root} ->
          if MapSet.member?(available_values, root) do
            :ok
          else
            error(
              "emit #{inspect(emit.event)} in workflow #{inspect(workflow.name)} maps from unknown workflow value #{inspect(root)}"
            )
          end

        :error ->
          error(
            "emit #{inspect(emit.event)} in workflow #{inspect(workflow.name)} has invalid map source #{inspect(mapping.from)}"
          )
      end
    end)
  end

  defp validate_automation_mappings(automation, workflow) do
    input_names =
      workflow.inputs
      |> List.wrap()
      |> Enum.map(& &1.name)
      |> MapSet.new()

    each(automation.mappings || [], fn mapping ->
      target = mapping_target(mapping)

      if MapSet.member?(input_names, target) do
        :ok
      else
        error(
          "automation #{inspect(automation.name)} maps unknown workflow input #{inspect(target)} for workflow #{inspect(workflow.name)}"
        )
      end
    end)
  end

  defp validate_automation_event_refs(_automation, nil) do
    # 外部イベントがまだロードできない場合は、field単位の検証はスキップする。
    :ok
  end

  defp validate_automation_event_refs(automation, event) do
    field_names = event_field_names(event)

    with :ok <- validate_automation_mapping_sources(automation, field_names),
         :ok <- validate_idempotency_key(automation, field_names) do
      :ok
    end
  end

  defp validate_automation_mapping_sources(automation, field_names) do
    each(automation.mappings || [], fn mapping ->
      case event_payload_field(mapping.from) do
        {:ok, field} ->
          if MapSet.member?(field_names, field) do
            :ok
          else
            error(
              "automation #{inspect(automation.name)} maps from unknown event payload field #{inspect(field)}"
            )
          end

        :error ->
          error(
            "automation #{inspect(automation.name)} has invalid map source #{inspect(mapping.from)}"
          )
      end
    end)
  end

  defp validate_idempotency_key(automation, field_names) do
    invalid =
      automation.idempotency_key
      |> List.wrap()
      |> Enum.reject(&MapSet.member?(field_names, &1))

    case invalid do
      [] ->
        :ok

      _ ->
        error(
          "automation #{inspect(automation.name)} has idempotency_key fields not present in trigger event payload: #{inspect(invalid)}"
        )
    end
  end

  defp validate_cross_module_workflow_calls(workflow) do
    each(workflow.tasks || [], fn task ->
      case task.workflow do
        {module, sub_name} when is_atom(module) and is_atom(sub_name) ->
          validate_external_sub_workflow(task, workflow, module, sub_name)

        {module, sub_name, _args} when is_atom(module) and is_atom(sub_name) ->
          validate_external_sub_workflow(task, workflow, module, sub_name)

        _ ->
          :ok
      end
    end)
  end

  defp validate_external_sub_workflow(task, workflow, module, sub_name) do
    case fetch_external_workflow(module, sub_name) do
      {:ok, sub_workflow} ->
        sub_input_names =
          sub_workflow.inputs
          |> List.wrap()
          |> Enum.map(& &1.name)
          |> MapSet.new()

        task_requires = task.requires |> List.wrap() |> MapSet.new()
        extra = MapSet.difference(task_requires, sub_input_names)

        case MapSet.to_list(extra) do
          [] ->
            :ok

          extra_list ->
            error(
              "task #{inspect(task.name)} in workflow #{inspect(workflow.name)} passes values #{inspect(extra_list)} not declared as inputs in #{inspect(module)}.#{sub_name}"
            )
        end

      :unknown ->
        :ok

      {:error, message} ->
        error(message)
    end
  end

  defp fetch_external_workflow(module, workflow_name) do
    case Code.ensure_loaded(module) do
      {:module, ^module} ->
        try do
          module
          |> Shigoto.Info.workflows()
          |> Enum.find(&(&1.name == workflow_name))
          |> case do
            nil ->
              {:error,
               "Unknown external workflow #{inspect(workflow_name)} in module #{inspect(module)}"}

            workflow ->
              {:ok, workflow}
          end
        rescue
          _ -> :unknown
        end

      _ ->
        :unknown
    end
  end

  defp fetch_workflow(workflow_name, workflows_by_name, automation) do
    case Map.fetch(workflows_by_name, workflow_name) do
      {:ok, workflow} ->
        {:ok, workflow}

      :error ->
        error(
          "Unknown workflow #{inspect(workflow_name)} in automation #{inspect(automation.name)}"
        )
    end
  end

  defp resolve_trigger_event(event_name, events_by_name) when is_atom(event_name) do
    case Map.fetch(events_by_name, event_name) do
      {:ok, event} ->
        {:ok, event}

      :error ->
        error("Unknown event #{inspect(event_name)} in automation trigger")
    end
  end

  defp resolve_trigger_event({module, event_name}, _events_by_name)
       when is_atom(module) and is_atom(event_name) do
    case fetch_external_event(module, event_name) do
      {:ok, event} ->
        {:ok, event}

      :unknown ->
        # 外部モジュールがまだ読めない場合は、存在検証だけスキップする。
        # 最終的には全specを集めた後のcross-module検証で拾うのが安全。
        {:ok, nil}

      {:error, message} ->
        error(message)
    end
  end

  defp resolve_trigger_event(other, _events_by_name) do
    error(
      "Invalid automation trigger event #{inspect(other)}. Expected :event_name or {Module, :event_name}"
    )
  end

  defp fetch_external_event(module, event_name) do
    case Code.ensure_loaded(module) do
      {:module, ^module} ->
        try do
          module
          |> Shigoto.Info.events()
          |> Enum.find(&(&1.name == event_name))
          |> case do
            nil ->
              {:error,
               "Unknown external event #{inspect(event_name)} in module #{inspect(module)}"}

            event ->
              {:ok, event}
          end
        rescue
          _ ->
            :unknown
        end

      _ ->
        :unknown
    end
  end

  defp node_names(workflow) do
    []
    |> Kernel.++(Enum.map(workflow.assertions || [], & &1.name))
    |> Kernel.++(Enum.map(workflow.tasks || [], & &1.name))
    |> Kernel.++(Enum.map(workflow.decisions || [], & &1.name))
    |> MapSet.new()
  end

  defp flat_available_values(workflow) do
    input_values =
      workflow.inputs
      |> List.wrap()
      |> Enum.map(& &1.name)

    produced_values =
      workflow.tasks
      |> List.wrap()
      |> Enum.map(& &1.produces)
      |> Enum.reject(&is_nil/1)

    input_values
    |> Kernel.++(produced_values)
    |> MapSet.new()
  end

  defp event_field_names(event) do
    event.fields
    |> List.wrap()
    |> Enum.map(& &1.name)
    |> MapSet.new()
  end

  defp mapping_target(mapping) do
    cond do
      Map.has_key?(mapping, :target) -> mapping.target
      Map.has_key?(mapping, :input) -> mapping.input
      true -> nil
    end
  end

  defp source_root([root | _]) when is_atom(root), do: {:ok, root}
  defp source_root(_), do: :error

  defp event_payload_field([:event, field | _]) when is_atom(field), do: {:ok, field}
  defp event_payload_field([field | _]) when is_atom(field), do: {:ok, field}
  defp event_payload_field(_), do: :error

  defp tag_nodes(kind, nodes) do
    Enum.map(nodes, &{kind, &1})
  end

  defp duplicates(values) do
    values
    |> Enum.frequencies()
    |> Enum.filter(fn {_value, count} -> count > 1 end)
    |> Enum.map(fn {value, _count} -> value end)
  end

  defp each(enumerable, fun) do
    Enum.reduce_while(enumerable, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp error(message) do
    {:error, Spark.Error.DslError.exception(message: message)}
  end
end
