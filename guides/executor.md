# Executor

`Shigoto.Executor` is the primary runtime for Shigoto workflows. It evaluates
all workflow nodes as plain Elixir function calls outside any database
transaction, accumulates `persists` values into an `Ecto.Multi`, collects
`emit` payloads, and returns everything to the caller.

```
{:ok, context, persist_multi, emits} | {:error, reason, partial_context, partial_emits}
```

The caller is responsible for committing `persist_multi` and dispatching
`emits`. This design keeps domain logic free of transaction and messaging
concerns and makes those boundaries explicit at the call site.

## Entry points

### `Shigoto.Executor.run/4`

Run a named workflow directly.

```elixir
{:ok, ctx, persist_multi, emits} =
  Shigoto.Executor.run(
    MyApp.Workflows.OrderApproval,  # module
    :approve_order,                  # workflow name
    %{order_id: "abc123"},           # inputs
    repo: MyApp.Repo                 # options
  )
```

### `Shigoto.Executor.run_automation/4`

Run a workflow via an automation, mapping the event payload through the
automation's `map` declarations.

```elixir
{:ok, ctx, persist_multi, emits} =
  Shigoto.Executor.run_automation(
    MyApp.Workflows.OrderApproval,
    :on_order_submitted,
    event_payload,
    repo: MyApp.Repo
  )
```

### `Shigoto.Executor.run_workflow/3`

Run a workflow struct directly. Useful in tests or when you hold the workflow
struct yourself.

```elixir
[workflow] = Shigoto.Info.workflows(MyApp.Workflows.OrderApproval)
{:ok, ctx, persist_multi, emits} = Shigoto.Executor.run_workflow(workflow, inputs, opts)
```

## Options

| Option | Type | Description |
|---|---|---|
| `:repo` | any | Passed to domain functions that declare `:repo` in their arg spec. Not used to open a transaction. |
| `:module` | module | Current workflow module. Set automatically by `run/4`. |
| `:workflow_resolver` | `fn module, name -> {module, workflow}` | Override how sub-workflow names are resolved. |

## Return values

**`{:ok, context, persist_multi, emits}`** — all nodes succeeded.

- `context` is a plain `%{atom() => term()}` map containing every produced value
  and decision result.
- `persist_multi` is an `Ecto.Multi` ready for `Repo.transaction/2`. It is
  empty (`Ecto.Multi.new()`) when no `persists` are declared.
- `emits` is a list of `{event_ref, payload}` tuples in topological order.
  `event_ref` is `:event_name` for local events or `{module, :event_name}` for
  cross-module references.

**`{:error, reason, partial_context, partial_emits}`** — a node failed.

- `partial_context` holds everything accumulated up to the failure point.
- `partial_emits` holds any emit payloads collected before the failure.

### Error reasons

| Reason | Cause |
|---|---|
| `{:assertion_failed, name}` | Assertion returned `false` or `nil` |
| `{:task_failed, name, reason}` | Task returned `{:error, reason}` |
| `{:task_raised, name, exception}` | Task raised an exception |
| `{:unknown_branch, name, branch}` | Decision returned an atom not in `branches` |

## Execution model

1. **Seed** — declared `input` values are placed in the context.
2. **Topological sort** — nodes are ordered by their dependency graph.
3. **Walk** — each node is executed in dependency order, carrying
   `{context, skip_set, persist_multi, emits}`:
   - `:assert` — calls `evaluated_by`; aborts on falsy result.
   - `:task` (function) — calls `call`; stores `produces` value in context.
   - `:task` (sub-workflow) — recursively calls `run_workflow`; merges sub-multi and sub-emits.
   - `:decision` — calls `evaluated_by`; stores branch atom; adds non-taken
     branch descendants to the skip set.
   - `:emit` — builds payload from `map` declarations; appended to emits list.
4. **Return** — `{:ok, context, persist_multi, emits}`.

Nodes in the skip set are never evaluated. Their produces values never appear
in the context, and their `persists` values are never accumulated.

## Domain function invocation

The executor supports two MFA forms:

### Integer-arity form

```elixir
call {MyApp.Orders, :get_order, 1}
```

- `arity == length(requires)` → called with required values only.
- `arity == length(requires) + 1` → `repo` prepended as first argument.

```elixir
# requires: [:order_id]
# arity: 1  → get_order(order_id)
# arity: 2  → get_order(repo, order_id)
```

### List-form args

```elixir
call {MyApp.Orders, :get_order, [:repo, :order_id]}
```

Each element in the list is either `:repo` (replaced with `opts[:repo]`) or an
atom (looked up in the execution context). `requires` is inferred automatically,
excluding `:repo`.

```elixir
call {MyApp.Orders, :get_order, [:repo, :order_id]}
# → MyApp.Orders.get_order(repo, ctx.order_id)
```

### Return value normalisation

Domain functions may return:

| Return | Treated as |
|---|---|
| `{:ok, value}` | Success; `value` stored under `produces` |
| `{:error, reason}` | Failure; workflow aborts |
| Any other value | Success; the value itself stored under `produces` |

## Handling emits

After a workflow run, `emits` is a list of `{event_ref, payload}` tuples — one
per `emit` node that was reached. The caller decides what to do with them:

```elixir
{:ok, ctx, persist_multi, emits} = Shigoto.Executor.run(...)

# Commit DB changes and record outbox entries atomically
outbox_multi =
  Enum.reduce(emits, persist_multi, fn {event, payload}, m ->
    cs = OutboxEntry.changeset(%OutboxEntry{}, %{event: inspect(event), payload: payload})
    Ecto.Multi.insert(m, {:outbox, event}, cs)
  end)

{:ok, _} = MyApp.Repo.transaction(outbox_multi)
```

Use `Shigoto.Automation` to route emits to matching automations:

```elixir
index = Shigoto.Automation.index([MyApp.OrderWorkflows, MyApp.PaymentWorkflows])

{:ok, _ctx, persist_multi, emits} = Shigoto.Executor.run(...)
{:ok, _} = MyApp.Repo.transaction(persist_multi)

Shigoto.Automation.dispatch_all(index, emits, repo: MyApp.Repo)
```

See [Automation](automation.md) for the full dispatch API.

## Committing persists

`persist_multi` is a plain `Ecto.Multi` — pass it to your repo:

```elixir
{:ok, ctx, persist_multi, _emits} = Shigoto.Executor.run(...)

case MyApp.Repo.transaction(persist_multi) do
  {:ok, _results} -> {:ok, ctx}
  {:error, op, reason, _changes} -> {:error, {op, reason}}
end
```

Sub-workflow persists are merged into the parent's `persist_multi` automatically.
The full transaction covers all persists in the call tree.

## Testing workflows

Pass stub domain modules directly — no mocks or adapters required:

```elixir
test "approval path persists approved order" do
  inputs = %{order_id: "order-1", ordered_at: DateTime.utc_now()}

  assert {:ok, ctx, persist_multi, _emits} =
           Shigoto.Executor.run(MyApp.Workflows.OrderApproval, :approve_order, inputs,
             repo: Ecto.Adapters.SQL.Sandbox
           )

  assert ctx.approval_required == :not_required
  assert %Ecto.Changeset{action: :update} = ctx.approved_order
  refute Ecto.Multi.to_list(persist_multi) == []
end
```

Because domain functions run eagerly and outside any transaction, you can test
individual domain functions in isolation and compose them into workflow tests
without a full application stack.

## Custom workflow resolver

By default, sub-workflow names are resolved against the same module. Override
with `:workflow_resolver` to support dynamic dispatch, multi-tenant modules, or
test doubles:

```elixir
resolver = fn _module, name ->
  workflow = MyApp.WorkflowRegistry.fetch!(name)
  {workflow.module, workflow.struct}
end

Shigoto.Executor.run(module, :wf, inputs, workflow_resolver: resolver)
```
