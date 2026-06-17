# Diagram Generation

Shigoto can generate Mermaid flowchart diagrams from workflow specifications.
Diagrams are intended for stakeholders and non-programmers: they show business
flow, not implementation details.

## Quick start

```
# All Shigoto modules in the application
mix shigoto.diagram

# A specific module
mix shigoto.diagram MyApp.Workflows.OrderApproval

# Print to stdout
mix shigoto.diagram MyApp.Workflows.OrderApproval --stdout
```

## `mix shigoto.diagram`

```
mix shigoto.diagram [MODULE ...] [OPTIONS]
```

### Arguments

| Argument | Description |
|---|---|
| `MODULE ...` | One or more fully-qualified module names. If omitted, all Shigoto modules in the application are discovered automatically. |

### Options

| Option | Default | Description |
|---|---|---|
| `--format`, `-f` | `mermaid` | Output format. Currently only `mermaid` is supported. |
| `--out`, `-o` | `diagrams` | Output directory. |
| `--workflow` | — | Only generate for workflows with this name. Useful for modules with multiple workflows. |
| `--direction` | `TD` | Mermaid flowchart direction: `TD` (top-down), `LR` (left-right), `BT` (bottom-top), `RL` (right-left). |
| `--show-calls` | `false` | Include MFA / sub-workflow call details in task nodes. |
| `--show-inputs` | `false` | Include workflow input nodes and edges. |
| `--stdout` | `false` | Print diagram to stdout instead of writing files. |

### Output structure

One file per workflow:

```
diagrams/
  order_approval/
    approve_order.mermaid
  room_reserve/
    reserve_room.mermaid
```

The directory name is the last component of the module name, lowercased
(`MyApp.Workflows.OrderApproval` → `order_approval`). The filename is the
workflow name.

## Examples

```bash
# Top-down layout, all modules
mix shigoto.diagram

# Left-to-right, specific module
mix shigoto.diagram MyApp.Workflows.OrderApproval --direction LR

# Show call details (good for code review, bad for stakeholder docs)
mix shigoto.diagram MyApp.Workflows.OrderApproval --show-calls

# Write to docs/diagrams/ instead of diagrams/
mix shigoto.diagram --out docs/diagrams

# One workflow from a module that has several
mix shigoto.diagram MyApp.Workflows.OrderApproval --workflow approve_order

# Pipe into a preview tool
mix shigoto.diagram MyApp.Workflows.OrderApproval --stdout | mmdc -o diagram.svg
```

## What the diagram shows

The default diagram (`--show-calls false`, `--show-inputs false`) shows:

- **Automation trigger events** — external events that start the workflow.
- **Automation nodes** — the automation's role as a bridge.
- **Workflow subgraph** — a labelled box containing all workflow nodes.
- **Start node** — entry point within the workflow.
- **Assertions** — hexagon nodes.
- **Tasks** — rectangle nodes; sub-workflow tasks use double-border rectangles.
- **Decisions** — diamond nodes.
- **Emits** — ellipse nodes (domain events fired during the workflow).

Edges represent:

- **Data dependencies** (`requires`) — solid arrows.
- **Control ordering** (`after_nodes`) — solid arrows.
- **Decision branches** — bold arrows labelled with the branch name.

## Rendering Mermaid

The `.mermaid` files produced are standard
[Mermaid flowchart](https://mermaid.js.org/syntax/flowchart.html) syntax.
Render them with any Mermaid-compatible tool:

**VS Code** — install the
[Mermaid Preview](https://marketplace.visualstudio.com/items?itemName=bierner.markdown-mermaid)
extension and open the `.mermaid` file.

**GitHub / GitLab** — paste the diagram content into a fenced code block in a
Markdown file:

````markdown
```mermaid
flowchart TD
  ...
```
````

**CLI** — install the Mermaid CLI and render to PNG or SVG:

```bash
npm install -g @mermaid-js/mermaid-cli
mmdc -i diagrams/order_approval/approve_order.mermaid -o approve_order.svg
```

**Mermaid Live Editor** — paste into [mermaid.live](https://mermaid.live) for an
interactive preview.

## Programmatic access

The exporter is also available as a library function:

```elixir
diagram = Shigoto.Export.Mermaid.workflow(
  MyApp.Workflows.OrderApproval,
  :approve_order,
  direction: "LR",
  show_calls?: true,
  show_inputs?: true
)

File.write!("approve_order.mermaid", diagram)
```

### Options for `Shigoto.Export.Mermaid.workflow/3`

| Option | Type | Default | Description |
|---|---|---|---|
| `:direction` | `string` | `"TD"` | Flowchart direction. |
| `:show_inputs?` | `boolean` | `false` | Show input nodes. |
| `:show_technical_labels?` | `boolean` | `false` | Show edge labels like "depends on" and "after". |
| `:show_calls?` | `boolean` | `false` | Show MFA / workflow ref on task nodes. |
| `:show_map_edges?` | `boolean` | `false` | Show payload mapping edges inside emit nodes. |
| `:title?` | `boolean` | `true` | Include workflow title as a Mermaid comment. |

## Auto-discovery

When no modules are provided, `mix shigoto.diagram` discovers Shigoto modules by
inspecting all modules registered under `:application.get_key(app, :modules)`.
A module is recognised as a Shigoto module when it:

1. Is loadable (`Code.ensure_loaded?/1`).
2. Exports `spark_dsl_config/0` (generated by `use Shigoto`).
3. Has at least one workflow (`Shigoto.Info.workflows/1` returns a non-empty list).

For this to work, your Shigoto workflow modules must be compiled into the
application — they should live in `lib/`, not in `test/` or script files.

## CI integration

Add diagram generation to your CI pipeline to keep diagrams in sync with code:

```yaml
# .github/workflows/diagrams.yml
- name: Generate diagrams
  run: mix shigoto.diagram --out docs/diagrams

- name: Commit diagrams
  uses: stefanzweifel/git-auto-commit-action@v5
  with:
    commit_message: "chore: regenerate workflow diagrams"
    file_pattern: "docs/diagrams/**"
```
