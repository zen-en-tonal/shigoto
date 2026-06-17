defmodule Shigoto.Transformers.InferMetadata do
  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer
  alias Shigoto.Dsl

  def transform(dsl_state) do
    module = Transformer.get_persisted(dsl_state, :module)

    original_workflows = Transformer.get_entities(dsl_state, [:workflows])
    automations = Transformer.get_entities(dsl_state, [:automations])

    workflows = Enum.map(original_workflows, &process_workflow(&1, module))
    automations = infer_automation_runs(automations, workflows)

    dsl_state =
      Enum.reduce(Enum.zip(original_workflows, workflows), dsl_state, fn {original, updated}, state ->
        Transformer.replace_entity(state, [:workflows], updated, fn record ->
          record.__struct__ == updated.__struct__ and
            record.__identifier__ == original.__identifier__
        end)
      end)

    dsl_state =
      Enum.reduce(automations, dsl_state, fn automation, state ->
        Transformer.replace_entity(state, [:automations], automation)
      end)

    {:ok, dsl_state}
  end

  defp process_workflow(workflow, module) do
    workflow
    |> maybe_infer_workflow_name(module)
    |> Map.update(:tasks, [], &Enum.map(&1, fn n -> process_node(n) end))
    |> Map.update(:assertions, [], &Enum.map(&1, fn n -> process_node(n) end))
    |> Map.update(:decisions, [], &Enum.map(&1, fn n -> process_node(n) end))
    |> Map.update(:emits, [], &Enum.map(&1, fn n -> process_emit(n) end))
  end

  defp maybe_infer_workflow_name(%{name: :__default__} = workflow, module) do
    derived = module |> Module.split() |> List.last() |> Macro.underscore() |> String.to_atom()
    %{workflow | name: derived, __identifier__: derived}
  end

  defp maybe_infer_workflow_name(workflow, _module), do: workflow

  defp process_node(%Dsl.Task{} = task) do
    task
    |> infer_requires_from_call()
    |> infer_after_nodes()
  end

  defp process_node(%Dsl.Assertion{} = assertion) do
    assertion
    |> infer_requires_from_evaluated_by()
    |> infer_after_nodes()
  end

  defp process_node(%Dsl.Decision{} = decision) do
    decision
    |> infer_requires_from_evaluated_by()
    |> infer_after_nodes()
  end

  defp process_node(node), do: node

  defp process_emit(emit) do
    infer_after_nodes(emit)
  end

  defp infer_requires_from_call(%Dsl.Task{} = task) do
    mfa = task.call || task.workflow

    case mfa do
      {_, _, args} when is_list(args) ->
        requires = Enum.reject(args, &(&1 == :repo))
        %{task | requires: requires}

      _ ->
        task
    end
  end

  defp infer_requires_from_evaluated_by(node) do
    case node.evaluated_by do
      {_, _, args} when is_list(args) ->
        requires = Enum.reject(args, &(&1 == :repo))
        %{node | requires: requires}

      _ ->
        node
    end
  end

  defp infer_after_nodes(node) do
    case Map.get(node, :after_node) do
      nil ->
        node

      single ->
        current = Map.get(node, :after_nodes) || []

        unless single in current do
          %{node | after_nodes: [single | current]}
        else
          node
        end
    end
  end

  defp infer_automation_runs(automations, workflows) do
    single_name =
      case workflows do
        [single] -> single.name
        _ -> nil
      end

    Enum.map(automations, fn automation ->
      if is_nil(automation.run) && single_name do
        %{automation | run: single_name}
      else
        automation
      end
    end)
  end
end
