defmodule Shigoto.Export.Mermaid do
  def workflow(module, workflow_name) do
    ir = Shigoto.IR.build(module)

    workflow =
      Enum.find(ir.workflows, fn workflow ->
        workflow.name == workflow_name
      end)

    """
    flowchart TD
    #{automation_edges(ir.automations, workflow)}
    #{task_nodes(workflow)}
    #{task_edges(workflow)}
    #{decision_nodes(workflow)}
    #{emit_nodes(workflow)}
    """
  end

  defp automation_edges(automations, workflow) do
    automations
    |> Enum.filter(&(&1.run == workflow.name))
    |> Enum.map(fn automation ->
      "  #{automation.on}([#{automation.on}]) --> #{workflow.name}{{#{workflow.name}}}"
    end)
    |> Enum.join("\n")
  end

  defp task_nodes(workflow) do
    workflow.tasks
    |> Enum.map(fn task ->
      "  #{task.name}[#{task.name}]"
    end)
    |> Enum.join("\n")
  end

  defp task_edges(workflow) do
    workflow.tasks
    |> Enum.flat_map(fn task ->
      Enum.map(task.after || [], fn predecessor ->
        "  #{predecessor} --> #{task.name}"
      end)
    end)
    |> Enum.join("\n")
  end

  defp decision_nodes(workflow) do
    workflow.decisions
    |> Enum.map(fn decision ->
      "  #{decision.name}{#{decision.name}?}"
    end)
    |> Enum.join("\n")
  end

  defp emit_nodes(workflow) do
    workflow.emits
    |> Enum.map(fn emit ->
      "  #{emit.event}([#{emit.event}])"
    end)
    |> Enum.join("\n")
  end
end
