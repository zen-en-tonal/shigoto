defmodule Mix.Tasks.Shigoto.Diagram do
  use Mix.Task

  @shortdoc "Generate workflow diagrams from Shigoto DSL modules"

  @moduledoc """
  Generates Mermaid flowchart diagrams for Shigoto workflow modules.

  ## Usage

      mix shigoto.diagram [MODULE ...] [OPTIONS]

  If no modules are given, all Shigoto modules in the current application are
  discovered automatically.

  ## Options

      --format, -f   Output format. Only `mermaid` is supported (default).
      --out, -o      Output directory (default: `diagrams`).
      --workflow     Only generate for workflows matching this name.
      --direction    Mermaid flowchart direction: TD, LR, BT, RL (default: TD).
      --show-calls   Include MFA / sub-workflow call details in task nodes.
      --show-inputs  Include workflow input nodes.
      --stdout       Print to stdout instead of writing files.

  ## Output structure

  One file per workflow, written to:

      {out}/{module_base}/{workflow_name}.mermaid

  where `module_base` is the last component of the module name, lowercased.

  ## Examples

      # All Shigoto modules in the app
      mix shigoto.diagram

      # Specific module
      mix shigoto.diagram MyApp.Workflows.OrderApproval

      # Multiple modules, left-to-right layout, technical details visible
      mix shigoto.diagram MyApp.Workflows.OrderApproval MyApp.Workflows.Onboarding \\
        --direction LR --show-calls

      # Print to stdout (useful for piping into a preview tool)
      mix shigoto.diagram MyApp.Workflows.OrderApproval --stdout

      # Write to docs/diagrams/
      mix shigoto.diagram --out docs/diagrams
  """

  @switches [
    format: :string,
    out: :string,
    workflow: :string,
    direction: :string,
    show_calls: :boolean,
    show_inputs: :boolean,
    stdout: :boolean
  ]

  @aliases [
    f: :format,
    o: :out
  ]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, module_args, invalid} = OptionParser.parse(args, switches: @switches, aliases: @aliases)

    unless invalid == [] do
      unrecognised = Enum.map_join(invalid, ", ", fn {k, _} -> k end)
      Mix.raise("Unrecognised options: #{unrecognised}")
    end

    format = Keyword.get(opts, :format, "mermaid")
    out_dir = Keyword.get(opts, :out, "diagrams")
    workflow_filter = Keyword.get(opts, :workflow)
    stdout = Keyword.get(opts, :stdout, false)

    diagram_opts = [
      direction: Keyword.get(opts, :direction, "TD"),
      show_calls?: Keyword.get(opts, :show_calls, false),
      show_inputs?: Keyword.get(opts, :show_inputs, false)
    ]

    modules =
      case module_args do
        [] ->
          discovered = discover_shigoto_modules()

          if discovered == [] do
            Mix.shell().info("No Shigoto modules found in the application.")
          end

          discovered

        args ->
          Enum.map(args, fn name ->
            module = Module.concat([name])

            unless Code.ensure_loaded?(module) do
              Mix.raise("Module #{name} could not be loaded. Is it compiled?")
            end

            unless shigoto_module?(module) do
              Mix.raise("#{name} is not a Shigoto module (no workflows defined).")
            end

            module
          end)
      end

    workflows_to_generate =
      for module <- modules,
          workflow <- Shigoto.Info.workflows(module),
          workflow_filter == nil or Atom.to_string(workflow.name) == workflow_filter do
        {module, workflow}
      end

    if workflows_to_generate == [] and workflow_filter != nil do
      Mix.shell().info("No workflows named #{inspect(workflow_filter)} found.")
    end

    Enum.each(workflows_to_generate, fn {module, workflow} ->
      diagram = generate(format, module, workflow.name, diagram_opts)

      if stdout do
        Mix.shell().info(diagram)
      else
        path = output_path(out_dir, format, module, workflow.name)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, diagram)
        Mix.shell().info("  #{path}")
      end
    end)
  end

  # ── Format dispatch ────────────────────────────────────────────────────────

  defp generate("mermaid", module, workflow_name, opts) do
    Shigoto.Export.Mermaid.workflow(module, workflow_name, opts)
  end

  defp generate(format, _module, _workflow_name, _opts) do
    Mix.raise("Unsupported format #{inspect(format)}. Supported formats: mermaid")
  end

  defp format_extension("mermaid"), do: ".mermaid"
  defp format_extension(fmt), do: ".#{fmt}"

  # ── Output path ────────────────────────────────────────────────────────────

  defp output_path(out_dir, format, module, workflow_name) do
    module_base =
      module
      |> Module.split()
      |> List.last()
      |> Macro.underscore()

    filename = "#{workflow_name}#{format_extension(format)}"
    Path.join([out_dir, module_base, filename])
  end

  # ── Auto-discovery ─────────────────────────────────────────────────────────

  defp discover_shigoto_modules do
    app = Mix.Project.config()[:app]

    case :application.get_key(app, :modules) do
      {:ok, modules} ->
        Enum.filter(modules, &shigoto_module?/1)

      :undefined ->
        Mix.shell().error("Could not load application modules. Is the app compiled?")
        []
    end
  end

  defp shigoto_module?(module) do
    Code.ensure_loaded?(module) and
      function_exported?(module, :spark_dsl_config, 0) and
      match?([_ | _], Shigoto.Info.workflows(module))
  rescue
    _ -> false
  end
end
