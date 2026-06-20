# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
mix deps.get       # Install dependencies
mix compile        # Compile
mix test           # Run all tests
mix test test/shigoto_test.exs  # Run a single test file
mix format         # Format code
```

## Architecture

Shigoto is an Elixir library providing a declarative DSL for defining **domain workflow specifications**. It does not execute workflows — it represents them as structured data for validation, documentation, and visualization.

### Core Concepts

Three top-level DSL constructs:

| Construct | Purpose |
|---|---|
| `event` | A domain occurrence (named in past tense, e.g. `:order_submitted`) |
| `workflow` | A dependency graph of `task`, `decision`, `assert`, and `emit` nodes |
| `automation` | Maps a triggering event to a workflow, with payload field mappings |

### Module Map

- **`lib/shigoto.ex`** — Entry point. `use Shigoto` delegates to `Shigoto.Base`.
- **`lib/shigoto/base.ex`** — Sets up Spark DSL with `Shigoto.Dsl` as the extension.
- **`lib/shigoto/dsl.ex`** — Defines all Spark entities and sections (`Event`, `Workflow`, `Automation`, `Task`, `Decision`, `Emit`, `Mapping`, etc.) and registers three verifiers.
- **`lib/shigoto/info.ex`** — Generated query API via `Spark.InfoGenerator`; use `Shigoto.Info.events/1`, `Shigoto.Info.workflows/1`, `Shigoto.Info.automations/1`.
- **`lib/shigoto/ir.ex`** — `Shigoto.IR.build/1` converts a module into plain maps for downstream processing.
- **`lib/shigoto/graph.ex`** — Builds a `%Shigoto.Graph{}` from a workflow struct; edges come from `after`, `requires`, `decision.branches`, and `emit` mappings. Used for cycle detection via Erlang `:digraph`/`:digraph_utils`. Prefer `with_digraph/2` over `to_digraph/1` to ensure cleanup.

### DSL Syntax

Two equivalent syntaxes are supported — inline keyword list and block form:

```elixir
# Inline (used in tests)
task :load_order,
  call: {MyApp.Orders, :get_order, 1},
  requires: [:order_id],
  produces: :order

# Block form (used in examples)
task :load_order do
  call {MyApp.Orders, :get_order, [:repo, :order_id]}
  produces :order
end
```

### Dependency Model

Within a workflow, two types of edges exist:
- **Data dependency** — `requires:` pulls a value produced by a prior `task.produces`; the graph resolves producer nodes automatically.
- **Control dependency** — `after:` (or `after_nodes:`) forces ordering without data flow.

`decision` nodes use `branches:` to map result atoms to successor node names. `Shigoto.Executor` evaluates only the selected branch.

### Verifiers

Three compile-time verifiers run on each module that `use Shigoto`:
- `ValidateReferences` — event/workflow cross-references (`automation.on`, `emit.event`, `automation.run`, `subflow.run`)
- `ValidateTaskXor` — ensures each task has exactly one of `call:` or `workflow:`
- `ValidateCyclic` — rejects workflows with cycles using `Shigoto.Graph.validate_acyclic/2`
