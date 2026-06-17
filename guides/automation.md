# Automation

`Shigoto.Automation` provides pure, stateless helpers for routing `emit` tuples
returned by `Shigoto.Executor` to matching `automation` declarations across your
Shigoto modules.

## Overview

After a workflow run, the executor returns a list of `{event_ref, payload}`
emit tuples. `Shigoto.Automation` gives you the glue to find which automations
are triggered by those emits and run them:

```elixir
# Build the index once — cache it in process state or ETS
index = Shigoto.Automation.index([MyApp.OrderWorkflows, MyApp.PaymentWorkflows])

# After any workflow run
{:ok, _ctx, persist_multi, emits} = Shigoto.Executor.run(...)
{:ok, _} = MyApp.Repo.transaction(persist_multi)

# Dispatch all emits — event type is inferred from each {event_ref, payload} tuple
results = Shigoto.Automation.dispatch_all(index, emits, repo: MyApp.Repo)
# [{:on_order_placed, {:ok, ctx, multi, emits}}, ...]
```

All functions are stateless — no process, no GenServer. Build and cache the
index; call the helpers wherever you handle executor output.

## Index

`Shigoto.Automation.index/1` builds a precomputed `event_ref => [auto_ref]` map
from a list of Shigoto modules. Call it once at startup.

```elixir
index = Shigoto.Automation.index([MyApp.OrderWorkflows, MyApp.PaymentWorkflows])
# %{
#   :order_placed  => [{MyApp.OrderWorkflows, :on_order_placed}],
#   :payment_made  => [{MyApp.PaymentWorkflows, :on_payment_made}],
# }
```

Order within a key follows the `modules` list, then declaration order within
each module.

## Matching

`Shigoto.Automation.match/2` returns `[{module, automation_name}]` for a given
emit or bare event ref. Pass the raw emit tuple directly — no need to destructure.

```elixir
# Emit tuple form — the natural input from Executor
Shigoto.Automation.match(index, {:order_placed, %{order_id: "123"}})
# [{MyApp.OrderWorkflows, :on_order_placed}]

# Bare event ref — same result
Shigoto.Automation.match(index, :order_placed)

# Module list — builds index on the fly (convenient for one-off use)
Shigoto.Automation.match([MyApp.OrderWorkflows], {:order_placed, %{order_id: "123"}})
```

Cross-module event refs (the `{Module, :event_name}` form) work the same way:

```elixir
Shigoto.Automation.match(index, {{MyApp.OrderWorkflows, :order_placed}, %{order_id: "123"}})
```

## Dispatch

`Shigoto.Automation.dispatch/2-3` matches an emit and runs all matching
automations. Results are returned as `[{automation_name, run_result}]`. All
matches are attempted regardless of individual failures.

```elixir
results = Shigoto.Automation.dispatch(index, {:order_placed, %{order_id: "123"}}, repo: MyApp.Repo)
# [{:on_order_placed, {:ok, ctx, multi, emits}}]
```

`Shigoto.Automation.dispatch_all/2-3` is a convenience wrapper over a list of emits:

```elixir
results = Shigoto.Automation.dispatch_all(index, emits, repo: MyApp.Repo)
# flat list of {automation_name, run_result} in emit order
```

Both accept either a precomputed index or a raw module list as the first argument.

## Idempotency

Automation declarations can list `idempotency_key` fields. Use
`Shigoto.Automation.idempotency_key/2` to extract a deduplication key before
dispatching:

```elixir
automation :customer_made_order do
  on {MyApp.Workflows.OrderSubmission, :order_submitted}
  idempotency_key [:order_id]
  map :prompt, from: [:prompt]
  map :customer_id, from: [:customer_id]
end
```

```elixir
auto_ref = {MyApp.Workflows.RoomReserve, :customer_made_order}
emit     = {{MyApp.Workflows.OrderSubmission, :order_submitted}, %{order_id: "order_1"}}

Shigoto.Automation.idempotency_key(auto_ref, emit)
# => "customer_made_order:order_1"
```

The key format is `"automation_name:v1:v2:...:vN"` in declaration order.
Returns `nil` when `idempotency_key` is not declared.

Both atom and string payload keys are tried (atom first).

### Example — manual idempotency check before dispatch

```elixir
for auto_ref <- Shigoto.Automation.match(index, emit) do
  key = Shigoto.Automation.idempotency_key(auto_ref, emit)

  if key == nil or not already_processed?(key) do
    Shigoto.Automation.dispatch(index, emit, repo: MyApp.Repo)
    mark_processed(key)
  end
end
```

## API summary

| Function | Description |
|---|---|
| `index([module])` | Build precomputed event → automations map |
| `match(source, emit \| event_ref)` | Find matching `{module, auto_name}` pairs |
| `idempotency_key(auto_ref, emit)` | Build deduplication key string from payload |
| `dispatch(source, emit, opts \\ [])` | Run automations for one emit |
| `dispatch_all(source, emits, opts \\ [])` | Run automations for a list of emits |
