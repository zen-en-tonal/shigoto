# DSL Reference

Shigoto provides three top-level constructs: `event`, `workflow`, and
`automation`. All are declared inside a module that calls `use Shigoto`.

```elixir
defmodule MyApp.Workflows.OrderApproval do
  use Shigoto

  event   :order_approved do ... end
  workflow :approve_order do ... end
  automation :on_order_submitted do ... end
end
```

---

## `event`

Declares a domain occurrence. Events are named in past tense to indicate
something that has already happened.

```elixir
event :order_approved do
  field :order_id, :uuid, required?: true
  field :approved_by, :user_id
end
```

### Fields

| Field | Type | Required | Description |
|---|---|---|---|
| `name` | `atom` | yes | Positional. Event identifier. |

### `field`

Describes one entry in the event payload.

```elixir
field :order_id, :uuid, required?: true
```

| Option | Type | Default | Description |
|---|---|---|---|
| `name` | `atom` | — | Positional. Payload key. |
| `type` | `atom` | — | Positional. Semantic type (`:uuid`, `:string`, `:integer`, …). |
| `required?` | `boolean` | `false` | Whether the field must always be present. |

---

## `workflow`

Declares a domain operation graph. A workflow is not an ordered procedure —
it is a dependency graph where execution order is derived from `requires`/`produces`
relationships.

```elixir
# Named workflow
workflow :approve_order do
  ...
end

# Anonymous workflow (name inferred from the module's last component)
workflow do
  ...
end
```

An anonymous `workflow do...end` block names itself after the enclosing module.
`MyApp.Workflows.RoomReserve` → `:room_reserve`. Use the named form when the
module hosts multiple workflows.

### Top-level options

| Option | Type | Default | Description |
|---|---|---|---|
| `name` | `atom` | inferred | Workflow identifier. Referenced by `automation.run` and sub-workflow `task.workflow`. |
| `persists` | `list(atom)` | `[]` | Names of produced values to collect as DB operations. See [Persistence](persistence.md). |

### `input` / `inputs`

Declares values the workflow expects from the caller. Two equivalent forms:

```elixir
# Block form — one at a time
input :order_id, :uuid
input :ordered_at, :datetime

# Keyword shorthand — multiple at once
inputs [
  order_id: :uuid,
  ordered_at: :datetime,
]
```

| Option | Type | Default | Description |
|---|---|---|---|
| `name` | `atom` | — | Positional. Input identifier. |
| `type` | `atom` | — | Positional. Semantic type. |
| `required?` | `boolean` | `true` | Whether the executor raises when this input is missing. |

---

### `assert`

Declares a precondition. The executor calls the given function; if it returns
falsy the workflow aborts with `{:assertion_failed, name}`.

```elixir
assert :order_is_fresh do
  evaluated_by {MyApp.OrderPolicy, :fresh?, [:ordered_at]}
end
```

| Option | Type | Required | Description |
|---|---|---|---|
| `name` | `atom` | yes | Positional. Assertion identifier. |
| `evaluated_by` | MFA | yes | Function that evaluates the condition. |
| `requires` | `list(atom)` | inferred | Values needed. Inferred from list-form `evaluated_by`. |
| `after_nodes` | `list(atom)` | `[]` | Control-order predecessors. |
| `after_node` | `atom` | — | Singular alias for `after_nodes`. |
| `summary` | `string` | — | Human-readable description for diagrams. |

---

### `task`

Declares a domain operation. A task calls one domain function (or delegates to
a sub-workflow).

```elixir
# Function task
task :load_order do
  call {MyApp.Orders, :get_order, [:repo, :order_id]}
  produces :order
  after_node :order_is_fresh
end

# Sub-workflow task
task :request_approval do
  workflow {MyApp.Workflows.Approvals, :request_manager_approval}
  requires [:order]
  produces :approval_request
end
```

| Option | Type | Required | Description |
|---|---|---|---|
| `name` | `atom` | yes | Positional. Task identifier. |
| `call` | MFA | one of `call`/`workflow` | Function to call. |
| `workflow` | ref | one of `call`/`workflow` | Sub-workflow to run. |
| `requires` | `list(atom)` | inferred | Values needed as inputs. Inferred from list-form `call`/`workflow`. |
| `produces` | `atom` | — | Name under which the return value is stored in the execution context. Defaults to `name`. |
| `after_nodes` | `list(atom)` | `[]` | Control-order predecessors. |
| `after_node` | `atom` | — | Singular alias for `after_nodes`. |
| `summary` | `string` | — | Human-readable description for diagrams. |

#### MFA forms

**Integer arity** — classic form. The executor prepends `repo` when
`arity == length(requires) + 1`:

```elixir
call {MyApp.Orders, :get_order, 1}   # get_order(order_id)
call {MyApp.Orders, :get_order, 2}   # get_order(repo, order_id)
```

**List-form args** — explicit, self-documenting. The executor maps `:repo` to the
`:repo` option, other atoms to the execution context. `requires` is inferred
automatically (`:repo` excluded):

```elixir
call {MyApp.Orders, :get_order, [:repo, :order_id]}
# → MyApp.Orders.get_order(repo, ctx.order_id)
# requires: [:order_id]  ← inferred
```

**Sub-workflow reference** — two-tuple or three-tuple:

```elixir
workflow {MyApp.Workflows.Approvals, :request_manager_approval}
workflow {MyApp.Workflows.Approvals, :request_manager_approval, [:order]}
```

The three-tuple's arg list infers `requires` the same way as list-form `call`.

---

### `decision`

Declares a branching point. The evaluated function returns an atom that selects
the next node.

```elixir
decision :approval_required do
  evaluated_by {MyApp.OrderPolicy, :approval_required?, [:order]}
  branches [
    required:     :request_approval,
    not_required: :mark_approved,
  ]
end
```

| Option | Type | Required | Description |
|---|---|---|---|
| `name` | `atom` | yes | Positional. Decision identifier. |
| `evaluated_by` | MFA | yes | Function returning a branch atom. |
| `requires` | `list(atom)` | inferred | Values needed. Inferred from list-form `evaluated_by`. |
| `branches` | `keyword(atom)` | yes | Maps return atoms to successor node names. |
| `after_nodes` | `list(atom)` | `[]` | Control-order predecessors. |
| `after_node` | `atom` | — | Singular alias for `after_nodes`. |
| `summary` | `string` | — | Human-readable description for diagrams. |

The executor stores the chosen branch atom in the context under the decision's
name. Nodes reachable only through non-taken branches are skipped; their
`persists` values are never accumulated.

---

### `emit`

Declares an event that may be fired after a workflow node completes.

```elixir
emit :order_approved do
  after_node :mark_approved
  map :order_id, from: [:order, :id]
  map :approved_by, from: [:approved_by]
end
```

| Option | Type | Required | Description |
|---|---|---|---|
| `event` | `atom` | yes | Positional. Must match a declared `event`. |
| `after_nodes` | `list(atom)` | `[]` | Nodes that must complete before the callback fires. |
| `after_node` | `atom` | — | Singular alias. |

Emits are deferred until all workflow nodes have run; callbacks receive the final
execution context. Pass the callback via the `:emit` option of `Shigoto.Executor.run/4`.

#### `map` inside `emit`

Maps workflow context values into the event payload:

```elixir
map :order_id, from: [:order, :id]   # event.order_id = ctx.order.id
map :approved_by, from: [:approved_by]  # event.approved_by = ctx.approved_by
```

| Option | Type | Required | Description |
|---|---|---|---|
| `target` | `atom` | yes | Positional. Event payload key. |
| `from` | `list(atom)` | yes | Path into the execution context. First element is the context key, remaining elements are nested struct/map keys. |

---

## `automation`

Connects an external event to a workflow. When the event fires, the automation
maps payload fields to workflow inputs and starts the workflow.

```elixir
automation :on_order_submitted do
  on {MyApp.Workflows.OrderSubmission, :order_submitted}
  run :approve_order
  idempotency_key [:order_id]

  map :order_id,   from: [:order_id]
  map :ordered_at, from: [:ordered_at]
end
```

| Option | Type | Required | Description |
|---|---|---|---|
| `name` | `atom` | yes | Positional. Automation identifier. |
| `on` | `atom` or `{module, atom}` | yes | Triggering event. Use `{Module, :event}` for cross-module events. |
| `run` | `atom` | inferred | Workflow to run. Inferred when the module has exactly one workflow. |
| `idempotency_key` | `list(atom)` | `[]` | Payload fields used to derive a deduplication key. |

#### `map` inside `automation`

Maps event payload fields to workflow inputs:

```elixir
map :order_id, from: [:order_id]   # workflow input :order_id = payload.order_id
```

The `target` (positional arg) must match a declared `input` of the target
workflow. `from` is a path into the event payload.

---

## Inline vs. block syntax

All DSL entities support both forms interchangeably:

```elixir
# Inline keyword list
task :load_order,
  call: {MyApp.Orders, :get_order, 1},
  requires: [:order_id],
  produces: :order

# Block form
task :load_order do
  call {MyApp.Orders, :get_order, 1}
  requires [:order_id]
  produces :order
end
```

Use whichever reads most clearly. The block form works well when a node has
nested entities (`emit`, `map`) or many options.

---

## Compile-time verification

Shigoto runs three verifiers at compile time:

**`ValidateReferences`** — all cross-references exist:
- `emit.event` → declared `event`
- `automation.on` → declared `event` (same or other module)
- `automation.run` → declared `workflow`
- sub-workflow `task.workflow` → declared `workflow`
- `task.after_nodes`, `decision.branches` targets → nodes in the same workflow
- `task.requires` → reachable from ancestors (topology-aware via digraph)

**`ValidateTaskXor`** — each task has exactly one of `call:` or `workflow:`.
When the target module is already compiled, also verifies the function is
exported and arity matches `requires` count.

**`ValidateCyclic`** — no cycles in the workflow dependency graph.

---

## Naming conventions

| Construct | Convention | Examples |
|---|---|---|
| `event` | Past tense | `:order_submitted`, `:payment_authorized` |
| `workflow` | Verb phrase | `:approve_order`, `:prepare_shipment` |
| `automation` | Causal phrase | `:on_order_submitted`, `:start_shipping_after_payment` |
| `task` | Verb phrase | `:load_order`, `:evaluate_policy` |
| `decision` | Noun/question | `:approval_required`, `:payment_retryable` |
| `assert` | Condition | `:order_is_fresh`, `:customer_eligible` |

Node names appear in generated diagrams. Prefer names a non-programmer can read.
