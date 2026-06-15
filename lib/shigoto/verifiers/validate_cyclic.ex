defmodule Shigoto.Verifiers.ValidateCyclic do
  use Spark.Dsl.Verifier

  def verify(dsl_state) do
    Shigoto.Info.workflows(dsl_state)
    |> validate_workflows()
  end

  defp validate_workflows(workflows) do
    each(workflows, fn workflow ->
      validate_workflow_graph(workflow)
    end)
  end

  defp validate_workflow_graph(workflow) do
    graph = Shigoto.Graph.workflow_graph(workflow)

    case Shigoto.Graph.validate_acyclic(graph) do
      {:ok, _topsort} ->
        :ok

      {:error, message} ->
        error(message)
    end
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
