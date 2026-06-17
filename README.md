# Shigoto

A declarative Elixir DSL for defining **domain workflow specifications**.

Shigoto lets you describe domain workflows as structured data — their tasks,
decisions, assertions, events, and dependencies — without coupling the
specification to any execution framework. The same specification can be
validated at compile time, visualised as a diagram, documented for stakeholders,
and executed by the built-in eager runner.

```elixir
defmodule MyApp.Workflows.OrderApproval do
  use Shigoto

  event :order_approved do
    field :order_id, :uuid, required?: true
  end

  workflow do
    inputs [order_id: :uuid, ordered_at: :datetime]

    assert :order_is_fresh do
      evaluated_by {MyApp.OrderPolicy, :fresh?, [:ordered_at]}
    end

    task :load_order do
      call {MyApp.Orders, :get_order, [:repo, :order_id]}
      produces :order
      after_node :order_is_fresh
    end

    decision :approval_required do
      evaluated_by {MyApp.OrderPolicy, :approval_required?, [:order]}
      branches [required: :request_approval, not_required: :mark_approved]
    end

    task :mark_approved do
      call {MyApp.Orders, :mark_approved, [:repo, :order]}
      produces :approved_order
    end

    emit :order_approved do
      after_node :mark_approved
      map :order_id, from: [:order, :id]
    end

    persists [:approved_order]
  end

  automation :on_order_submitted do
    on {MyApp.Workflows.OrderSubmission, :order_submitted}
    map :order_id, from: [:order_id]
    map :ordered_at, from: [:ordered_at]
  end
end
```

Execute it:

```elixir
{:ok, ctx, persist_multi} =
  Shigoto.Executor.run(MyApp.Workflows.OrderApproval, :order_approval, inputs, repo: MyApp.Repo)

{:ok, _} = MyApp.Repo.transaction(persist_multi)
```

Generate a diagram:

```
mix shigoto.diagram MyApp.Workflows.OrderApproval --direction LR
```

## Installation

Add `shigoto` to your dependencies:

```elixir
# mix.exs
def deps do
  [
    {:shigoto, "~> 0.1"},
    # Optional — required only if you use persists or Shigoto.Ecto.ChangesetMulti
    {:ecto, "~> 3.0", optional: true}
  ]
end
```

Shigoto is built on [Spark](https://hexdocs.pm/spark), which is pulled in
automatically.

## Core concepts

| Construct | Purpose |
|---|---|
| `event` | A domain occurrence, named in past tense (`:order_submitted`) |
| `workflow` | A dependency graph of tasks, decisions, assertions, and emits |
| `automation` | Connects a triggering event to a workflow with input mappings |

### Workflows are dependency graphs, not procedures

Tasks and decisions declare what values they *require* and what they *produce*.
Shigoto resolves execution order from those data dependencies — you don't specify
steps, you specify relationships.

```elixir
task :load_order do
  call {MyApp.Orders, :get_order, [:repo, :order_id]}
  produces :order                  # makes :order available to later nodes
end

task :evaluate_policy do
  call {MyApp.OrderPolicy, :evaluate, [:order]}
  produces :policy_result          # requires :order → runs after :load_order automatically
end
```

### Two edge types

- **Data dependency** — `requires:` (or inferred from list-form call args). A node
  runs after all producers of its required values.
- **Control dependency** — `after_nodes:` / `after_node:`. Forces ordering without
  data flow when needed.

### Domain functions are called directly

The executor calls your domain functions as plain Elixir calls — no middleware,
no wrappers. Functions that need a database connection declare `:repo` in their
arg spec; the executor injects it from the `:repo` option:

```elixir
task :load_order do
  call {MyApp.Orders, :get_order, [:repo, :order_id]}
  # → MyApp.Orders.get_order(repo, order_id)
end
```

Functions without `:repo` are called with their required values only:

```elixir
task :parse_prompt do
  call {MyApp.LLM, :parse, [:prompt]}
  # → MyApp.LLM.parse(prompt)
end
```

### Persistence is separate from execution

Functions run outside any DB transaction. Only values listed in `persists` become
DB operations, returned as an `Ecto.Multi` for the caller to commit:

```elixir
workflow do
  task :reserve do
    call {MyApp.Rooms, :reserve, [:rooms, :customer_id]}
    produces :reservation         # returns a changeset or ChangesetMulti
  end

  persists [:reservation]         # collected into the returned Ecto.Multi
end

{:ok, ctx, persist_multi} = Shigoto.Executor.run(...)
{:ok, _} = MyApp.Repo.transaction(persist_multi)
```

## What Shigoto validates at compile time

- All cross-references exist: `emit.event`, `automation.on`, `automation.run`,
  sub-workflow calls
- Each task declares exactly one of `call:` or `workflow:`
- No cyclic dependencies within a workflow
- Each node's `requires` are reachable from its ancestors (topology-aware)
- MFA exists when the target module is already compiled
- Arity matches requires count (for integer-arity form)

## Guides

- [DSL Reference](guides/dsl_reference.md) — complete syntax reference
- [Executor](guides/executor.md) — running workflows with `Shigoto.Executor`
- [Persistence](guides/persistence.md) — `persists`, `Shigoto.Ecto.ChangesetMulti`
- [Diagrams](guides/diagrams.md) — `mix shigoto.diagram`

## Diagram generation

```
# All Shigoto modules in the app
mix shigoto.diagram

# Specific module, left-to-right, with call details
mix shigoto.diagram MyApp.Workflows.OrderApproval --direction LR --show-calls

# Print to stdout
mix shigoto.diagram MyApp.Workflows.OrderApproval --stdout
```

Output is written to `diagrams/{module_base}/{workflow_name}.mermaid` by default.

## License

MIT
