defmodule Shigoto.Verifiers.ValidateTaskXor do
  use Spark.Dsl.Verifier

  def verify(dsl_state) do
    Shigoto.Info.workflows(dsl_state)
    |> validate_workflows()
  end

  defp validate_workflows(workflows) do
    each(workflows, fn workflow ->
      validate_task_call_specs(workflow)
    end)
  end

  defp validate_task_call_specs(workflow) do
    each(workflow.tasks || [], fn task ->
      has_call? = not is_nil(task.call)
      has_workflow? = not is_nil(task.workflow)

      cond do
        has_call? and has_workflow? ->
          error(
            "task #{inspect(task.name)} in workflow #{inspect(workflow.name)} must not specify both :call and :workflow"
          )

        not has_call? and not has_workflow? ->
          error(
            "task #{inspect(task.name)} in workflow #{inspect(workflow.name)} must specify either :call or :workflow"
          )

        has_call? ->
          validate_function_call(task.call, task, workflow)

        has_workflow? ->
          validate_workflow_call_shape(task.workflow, task, workflow)
      end
    end)
  end

  defp validate_function_call({module, function, arity}, task, workflow)
       when is_atom(module) and is_atom(function) and is_integer(arity) and arity >= 0 do
    with :ok <- check_function_exported(module, function, arity, task, workflow),
         :ok <- check_arity_vs_requires(arity, task, workflow) do
      :ok
    end
  end

  defp validate_function_call({module, function, arg_spec}, task, workflow)
       when is_atom(module) and is_atom(function) and is_list(arg_spec) do
    check_function_exported(module, function, length(arg_spec), task, workflow)
  end

  defp validate_function_call(other, task, workflow) do
    error(
      "task #{inspect(task.name)} in workflow #{inspect(workflow.name)} has invalid call #{inspect(other)}. Expected {Module, function, arity | arg_list}"
    )
  end

  defp validate_workflow_call_shape(workflow_name, _task, _workflow)
       when is_atom(workflow_name) do
    :ok
  end

  defp validate_workflow_call_shape({module, workflow_name}, _task, _workflow)
       when is_atom(module) and is_atom(workflow_name) do
    :ok
  end

  defp validate_workflow_call_shape({module, workflow_name, args}, _task, _workflow)
       when is_atom(module) and is_atom(workflow_name) and is_list(args) do
    :ok
  end

  defp validate_workflow_call_shape(other, task, workflow) do
    error(
      "task #{inspect(task.name)} in workflow #{inspect(workflow.name)} has invalid workflow call #{inspect(other)}. Expected :workflow_name or {Module, :workflow_name}"
    )
  end

  defp check_function_exported(module, function, arity, task, workflow) do
    case Code.ensure_loaded(module) do
      {:module, ^module} ->
        if function_exported?(module, function, arity) do
          :ok
        else
          error(
            "task #{inspect(task.name)} in workflow #{inspect(workflow.name)} calls #{inspect(module)}.#{function}/#{arity} which does not exist"
          )
        end

      _ ->
        :ok
    end
  end

  defp check_arity_vs_requires(arity, task, workflow) do
    requires_count = task.requires |> List.wrap() |> length()

    if arity in [requires_count, requires_count + 1] do
      :ok
    else
      error(
        "task #{inspect(task.name)} in workflow #{inspect(workflow.name)} declares arity #{arity} but has #{requires_count} requires values; expected #{requires_count} (no repo) or #{requires_count + 1} (with repo)"
      )
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
