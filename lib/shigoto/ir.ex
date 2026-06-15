defmodule Shigoto.IR do
  def build(module) do
    %{
      module: module,
      events: Enum.map(Shigoto.Info.events(module), &event_ir/1),
      workflows: Enum.map(Shigoto.Info.workflows(module), &workflow_ir/1),
      automations: Enum.map(Shigoto.Info.automations(module), &automation_ir/1)
    }
  end

  defp event_ir(event) do
    %{
      name: event.name,
      fields: event.fields
    }
  end

  defp workflow_ir(workflow) do
    %{
      name: workflow.name,
      inputs: workflow.inputs,
      assertions: workflow.assertions,
      tasks: workflow.tasks,
      decisions: workflow.decisions,
      emits: workflow.emits
    }
  end

  defp automation_ir(automation) do
    %{
      name: automation.name,
      on: automation.on,
      run: automation.run,
      mappings: automation.mappings
    }
  end
end
