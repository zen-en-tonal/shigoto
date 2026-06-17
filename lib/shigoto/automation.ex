defmodule Shigoto.Automation do
  @moduledoc """
  Pure helpers for matching emits to automations and dispatching them.

      index = Shigoto.Automation.index([MyApp.OrderWorkflows, MyApp.PaymentWorkflows])

      {:ok, _ctx, _multi, emits} = Shigoto.Executor.run(MyModule, :my_workflow, inputs)
      results = Shigoto.Automation.dispatch_all(index, emits, repo: MyRepo)
      # [{:on_order_placed, {:ok, ctx, multi, emits}}, ...]

  All functions are pure and stateless. Build the index once and cache it in
  process state or an ETS table.
  """

  @type event_ref :: atom() | {module(), atom()}
  @type emit :: {event_ref(), map() | keyword()}
  @type auto_ref :: {module(), atom()}
  @type index :: %{event_ref() => [auto_ref()]}

  @doc """
  Builds a precomputed `event_ref => [auto_ref]` index from a list of Shigoto modules.

  Order within a key follows the `modules` list, then declaration order within each module.
  """
  @spec index([module()]) :: index()
  def index(modules) do
    Enum.reduce(modules, %{}, fn mod, acc ->
      mod
      |> Shigoto.Info.automations()
      |> Enum.reduce(acc, fn auto, idx ->
        Map.update(idx, auto.on, [{mod, auto.name}], &(&1 ++ [{mod, auto.name}]))
      end)
    end)
  end

  @doc """
  Returns `[{module, automation_name}]` whose `on:` matches the given emit or event ref.

  Accepts a precomputed index (O(1)) or a module list (builds the index on the fly).
  Pass the raw `{event_ref, payload}` emit tuple directly — no need to destructure.
  """
  @spec match([module()] | index(), emit() | event_ref()) :: [auto_ref()]

  def match(idx, {event_ref, payload})
      when is_map(idx) and (is_map(payload) or is_list(payload)),
      do: Map.get(idx, event_ref, [])

  def match(idx, event_ref) when is_map(idx),
    do: Map.get(idx, event_ref, [])

  def match(modules, input) when is_list(modules),
    do: modules |> index() |> match(input)

  @doc """
  Returns the idempotency key string for an automation and emit payload.

  Format: `"automation_name:v1:v2:...:vN"` in `idempotency_key` declaration order.
  Returns `nil` when `idempotency_key` is not declared on the automation.
  Both atom and string payload keys are tried (atom first).

      iex> Shigoto.Automation.idempotency_key({MyApp.RoomReserve, :customer_made_order},
      ...>   {{MyApp.OrderSubmission, :order_submitted}, %{order_id: "order_1"}})
      "customer_made_order:order_1"
  """
  @spec idempotency_key(auto_ref(), emit()) :: String.t() | nil
  def idempotency_key({mod, auto_name}, {_event_ref, payload})
      when is_map(payload) or is_list(payload) do
    automation =
      Shigoto.Info.automations(mod)
      |> Enum.find(&(&1.name == auto_name))

    case List.wrap(automation.idempotency_key) do
      [] ->
        nil

      fields ->
        values = Enum.map(fields, &fetch_from_payload!(payload, &1))
        Enum.join([auto_name | values], ":")
    end
  end

  @doc """
  Runs all automations matching the given emit tuple.

  Returns `[{automation_name, run_result}]`. All matches are attempted regardless
  of individual failures. `opts` are forwarded to `Shigoto.Executor.run_automation/4`.
  """
  @spec dispatch([module()] | index(), emit(), keyword()) :: [
          {atom(), {:ok, map(), term(), list()} | {:error, term(), map(), list()}}
        ]
  def dispatch(source, {event_ref, payload} = _emit, opts \\ []) do
    source
    |> match(event_ref)
    |> Enum.map(fn {mod, auto_name} ->
      {auto_name, Shigoto.Executor.run_automation(mod, auto_name, payload, opts)}
    end)
  end

  @doc """
  Runs `dispatch/3` for every emit in the list, returning a flat result list in emit order.
  """
  @spec dispatch_all([module()] | index(), [emit()], keyword()) :: [
          {atom(), {:ok, map(), term(), list()} | {:error, term(), map(), list()}}
        ]
  def dispatch_all(source, emits, opts \\ []) do
    Enum.flat_map(emits, &dispatch(source, &1, opts))
  end

  defp fetch_from_payload!(payload, key) when is_map(payload) do
    case Map.fetch(payload, key) do
      {:ok, value} -> value
      :error ->
        case Map.fetch(payload, Atom.to_string(key)) do
          {:ok, value} -> value
          :error -> raise KeyError, "missing idempotency_key field #{inspect(key)} in payload"
        end
    end
  end

  defp fetch_from_payload!(payload, key) when is_list(payload) do
    case Keyword.fetch(payload, key) do
      {:ok, value} -> value
      :error -> raise KeyError, "missing idempotency_key field #{inspect(key)} in keyword payload"
    end
  end
end
