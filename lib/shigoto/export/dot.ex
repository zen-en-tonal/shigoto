defmodule Shigoto.Export.DOT do
  @moduledoc """
  Exports Shigoto workflows as Graphviz DOT.

  The default output is intended for non-programmers.

  It emphasizes business flow:

    * external event triggers
    * automations
    * workflow start
    * assertions
    * tasks
    * decisions
    * emitted domain events

  It intentionally hides most technical details such as:

    * data value names
    * `requires` labels
    * `produces`
    * MFA calls
    * payload mappings
  """

  @doc """
  Exports a workflow as Graphviz DOT.

  ## Options

    * `:rankdir` - Graphviz rank direction. Defaults to `"TB"`.
      Use `"LR"` for left-to-right diagrams.

    * `:show_inputs?` - whether to render workflow inputs. Defaults to `false`.

    * `:show_technical_labels?` - whether to show internal edge labels.
      Defaults to `false`.

    * `:show_calls?` - whether to show MFA / workflow call details.
      Defaults to `false`.

    * `:show_map_edges?` - whether to show event payload mapping edges.
      Defaults to `false`.

    * `:graph_name` - custom DOT graph name.

  ## Example

      Shigoto.Export.DOT.workflow(
        MyApp.Workflows.OrderApproval,
        :approve_order,
        rankdir: "LR"
      )

  """
  def workflow(module, workflow_name, opts \\ []) do
    workflow = fetch_workflow!(module, workflow_name)
    automations = automations_for_workflow(module, workflow_name)
    graph = Shigoto.Graph.workflow_graph(workflow)

    graph_name =
      Keyword.get(
        opts,
        :graph_name,
        "#{inspect(module)}.#{workflow_name}"
      )

    rankdir = Keyword.get(opts, :rankdir, "TB")
    show_inputs? = Keyword.get(opts, :show_inputs?, false)
    show_technical_labels? = Keyword.get(opts, :show_technical_labels?, false)
    show_calls? = Keyword.get(opts, :show_calls?, false)
    show_map_edges? = Keyword.get(opts, :show_map_edges?, false)

    node_index = node_index(workflow)

    vertices =
      graph.vertices
      |> MapSet.to_list()
      |> sort_terms()

    business_edges =
      graph.edges
      |> Enum.filter(&business_edge?(&1, show_map_edges?))

    entry_vertices =
      entry_vertices(graph, business_edges)

    [
      "digraph #{quoted(graph_name)} {",
      indent("graph [rankdir=#{quoted(rankdir)}, splines=ortho, overlap=false];"),
      indent("node [fontname=#{quoted("Helvetica")}, fontsize=10, margin=0.08];"),
      indent("edge [fontname=#{quoted("Helvetica")}, fontsize=9];"),
      "",
      indent("label=#{quoted(workflow_title(module, workflow))};"),
      indent("labelloc=#{quoted("t")};"),
      indent("fontsize=16;"),
      "",
      automation_nodes_and_edges(module, workflow, automations, entry_vertices),
      maybe_input_nodes(workflow, show_inputs?),
      maybe_input_edges(workflow, show_inputs?),
      workflow_cluster(
        module,
        workflow,
        vertices,
        node_index,
        show_calls?
      ),
      edge_lines(business_edges, show_technical_labels?),
      "}"
    ]
    |> List.flatten()
    |> Enum.reject(&(&1 == nil or &1 == ""))
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp fetch_workflow!(module, workflow_name) do
    module
    |> Shigoto.Info.workflows()
    |> Enum.find(&(&1.name == workflow_name))
    |> case do
      nil ->
        raise ArgumentError,
              "unknown Shigoto workflow #{inspect(workflow_name)} in #{inspect(module)}"

      workflow ->
        workflow
    end
  end

  defp automations_for_workflow(module, workflow_name) do
    module
    |> Shigoto.Info.automations()
    |> Enum.filter(&(&1.run == workflow_name))
  end

  defp workflow_title(module, workflow) do
    "#{humanize_module(module)} / #{humanize(workflow.name)}"
  end

  defp workflow_cluster(_module, workflow, vertices, node_index, show_calls?) do
    [
      indent("subgraph #{quoted("cluster_#{workflow.name}")} {"),
      indent2("label=#{quoted("Workflow: #{humanize(workflow.name)}")};"),
      indent2("style=#{quoted("rounded")};"),
      indent2("color=#{quoted("gray70")};"),
      indent2(
        "workflow_start_#{workflow.name} [label=#{quoted("開始")}, shape=oval, style=#{quoted("filled,rounded")}, fillcolor=#{quoted("gray95")}, color=#{quoted("gray60")}];"
      ),
      "",
      vertices
      |> Enum.map(fn vertex ->
        case Map.fetch(node_index, vertex) do
          {:ok, {:assert, assertion}} ->
            dot_node(vertex,
              label: assertion_label(assertion),
              shape: "hexagon",
              style: "rounded",
              fillcolor: "gray95"
            )

          {:ok, {:task, task}} ->
            dot_node(vertex,
              label: task_label(task, show_calls?),
              shape: task_shape(task),
              style: "rounded"
            )

          {:ok, {:decision, decision}} ->
            dot_node(vertex,
              label: decision_label(decision),
              shape: "diamond",
              style: "rounded"
            )

          {:ok, {:emit, {emit, _index}}} ->
            dot_node(vertex,
              label: emit_label(emit),
              shape: "ellipse",
              style: "rounded"
            )

          :error ->
            dot_node(vertex,
              label: humanize(vertex),
              shape: "box",
              style: "rounded"
            )
        end
      end),
      indent("}")
    ]
  end

  defp automation_nodes_and_edges(_module, _workflow, [], _entry_vertices), do: []

  defp automation_nodes_and_edges(_module, workflow, automations, entry_vertices) do
    start_vertex = "workflow_start_#{workflow.name}"

    automations
    |> Enum.with_index()
    |> Enum.flat_map(fn {automation, index} ->
      automation_id = automation_vertex(automation, index)
      event_id = event_vertex(automation.on, index)

      [
        dot_node_raw(event_id,
          label: trigger_event_label(automation.on),
          shape: "ellipse",
          style: "rounded"
        ),
        dot_node_raw(automation_id,
          label: automation_label(automation),
          shape: "box",
          style: "rounded,filled",
          fillcolor: "gray95"
        ),
        dot_edge_raw(event_id, automation_id, label: "トリガー"),
        dot_edge_raw(automation_id, start_vertex, label: "開始")
      ] ++
        Enum.map(entry_vertices, fn entry ->
          dot_edge_raw(start_vertex, vertex_id(entry), [])
        end)
    end)
  end

  defp maybe_input_nodes(_workflow, false), do: []

  defp maybe_input_nodes(workflow, true) do
    workflow.inputs
    |> list()
    |> Enum.map(fn input ->
      dot_node(input_vertex(input.name),
        label: "#{humanize(input.name)}\n#{input.type}",
        shape: "parallelogram",
        style: "rounded"
      )
    end)
  end

  defp maybe_input_edges(_workflow, false), do: []

  defp maybe_input_edges(workflow, true) do
    producer_by_value = producer_by_value(workflow)
    input_names = input_names(workflow)

    requiring_nodes(workflow)
    |> Enum.flat_map(fn {target_vertex, requires} ->
      requires
      |> list()
      |> Enum.filter(&MapSet.member?(input_names, &1))
      |> Enum.reject(&Map.has_key?(producer_by_value, &1))
      |> Enum.map(fn input_name ->
        dot_edge(input_vertex(input_name), target_vertex, style: "dashed")
      end)
    end)
  end

  defp edge_lines(edges, show_technical_labels?) do
    edges
    |> Enum.sort_by(fn edge ->
      {vertex_id(edge.from), vertex_id(edge.to), inspect(edge.kind), inspect(edge.label)}
    end)
    |> Enum.map(fn edge ->
      attrs = business_edge_attrs(edge, show_technical_labels?)
      dot_edge(edge.from, edge.to, attrs)
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp business_edge?(edge, show_map_edges?) do
    case edge.kind do
      :after -> true
      :requires -> true
      :branch -> true
      :map -> show_map_edges?
      _ -> false
    end
  end

  defp business_edge_attrs(edge, show_technical_labels?) do
    case {edge.kind, show_technical_labels?} do
      {:branch, _} ->
        [
          label: humanize(edge.label),
          style: "bold"
        ]

      {:after, true} ->
        [
          label: "after",
          style: "solid"
        ]

      {:after, false} ->
        [
          style: "solid"
        ]

      {:requires, true} ->
        [
          label: "depends on #{edge.label}",
          style: "solid"
        ]

      {:requires, false} ->
        [
          style: "solid"
        ]

      {:map, true} ->
        [
          label: "map #{edge.label}",
          style: "dotted"
        ]

      {:map, false} ->
        [
          style: "dotted"
        ]

      {_kind, _false} ->
        []
    end
  end

  defp entry_vertices(graph, business_edges) do
    vertices = graph.vertices

    incoming =
      business_edges
      |> Enum.map(& &1.to)
      |> MapSet.new()

    entries =
      MapSet.difference(vertices, incoming)

    if MapSet.size(entries) == 0 do
      vertices
      |> MapSet.to_list()
      |> Enum.take(1)
    else
      MapSet.to_list(entries)
    end
  end

  defp node_index(workflow) do
    assertions =
      workflow.assertions
      |> list()
      |> Map.new(fn assertion ->
        {assertion.name, {:assert, assertion}}
      end)

    tasks =
      workflow.tasks
      |> list()
      |> Map.new(fn task ->
        {task.name, {:task, task}}
      end)

    decisions =
      workflow.decisions
      |> list()
      |> Map.new(fn decision ->
        {decision.name, {:decision, decision}}
      end)

    emits =
      workflow.emits
      |> list()
      |> Enum.with_index()
      |> Map.new(fn {emit, index} ->
        {{:emit, workflow.name, emit.event, index}, {:emit, {emit, index}}}
      end)

    assertions
    |> Map.merge(tasks)
    |> Map.merge(decisions)
    |> Map.merge(emits)
  end

  defp requiring_nodes(workflow) do
    []
    |> Kernel.++(
      workflow.assertions
      |> list()
      |> Enum.map(fn assertion ->
        {assertion.name, assertion.requires}
      end)
    )
    |> Kernel.++(
      workflow.tasks
      |> list()
      |> Enum.map(fn task ->
        {task.name, task.requires}
      end)
    )
    |> Kernel.++(
      workflow.decisions
      |> list()
      |> Enum.map(fn decision ->
        {decision.name, decision.requires}
      end)
    )
  end

  defp producer_by_value(workflow) do
    workflow.tasks
    |> list()
    |> Enum.reduce(%{}, fn task, acc ->
      case task.produces do
        nil -> acc
        value -> Map.put(acc, value, task.name)
      end
    end)
  end

  defp input_names(workflow) do
    workflow.inputs
    |> list()
    |> Enum.map(& &1.name)
    |> MapSet.new()
  end

  defp assertion_label(assertion) do
    summary =
      Map.get(assertion, :summary) ||
        "前提確認"

    "#{humanize(assertion.name)}\n#{summary}"
  end

  defp task_label(task, false) do
    humanize(task.name)
  end

  defp task_label(task, true) do
    details =
      cond do
        Map.get(task, :workflow) != nil ->
          "workflow: #{format_workflow_ref(task.workflow)}"

        Map.get(task, :call) != nil ->
          "call: #{format_mfa(task.call)}"

        true ->
          nil
      end

    [
      humanize(task.name),
      details
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp task_shape(task) do
    if Map.get(task, :workflow) != nil do
      "component"
    else
      "box"
    end
  end

  defp decision_label(decision) do
    Map.get(decision, :summary) ||
      "#{humanize(decision.name)}?"
  end

  defp emit_label(emit) do
    "#{humanize(emit.event)}\nイベント発生"
  end

  defp automation_label(automation) do
    humanize(automation.name)
  end

  defp trigger_event_label({module, event}) do
    "#{humanize(event)}\n#{humanize_module(module)}"
  end

  defp trigger_event_label(event) when is_atom(event) do
    "#{humanize(event)}\n外部イベント"
  end

  defp trigger_event_label(other), do: inspect(other)

  defp format_mfa({module, function, arity})
       when is_atom(module) and is_atom(function) and is_integer(arity) do
    "#{inspect(module)}.#{function}/#{arity}"
  end

  defp format_mfa(other), do: inspect(other)

  defp format_workflow_ref(name) when is_atom(name), do: Atom.to_string(name)

  defp format_workflow_ref({module, name}) when is_atom(module) and is_atom(name) do
    "#{inspect(module)}.#{name}"
  end

  defp format_workflow_ref(other), do: inspect(other)

  defp input_vertex(input_name), do: {:input, input_name}

  defp automation_vertex(automation, index) do
    "automation:#{automation.name}:#{index}"
  end

  defp event_vertex(event, index) do
    "trigger_event:#{inspect(event)}:#{index}"
  end

  defp dot_node(vertex, attrs) do
    dot_node_raw(vertex_id(vertex), attrs)
  end

  defp dot_node_raw(id, attrs) do
    indent("#{quoted(id)} [#{dot_attrs(attrs)}];")
  end

  defp dot_edge(_from, _to, []) do
    nil
  end

  defp dot_edge(from, to, attrs) do
    dot_edge_raw(vertex_id(from), vertex_id(to), attrs)
  end

  defp dot_edge_raw(from, to, attrs) do
    if attrs == [] do
      indent("#{quoted(from)} -> #{quoted(to)};")
    else
      indent("#{quoted(from)} -> #{quoted(to)} [#{dot_attrs(attrs)}];")
    end
  end

  defp dot_attrs(attrs) do
    attrs
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.map(fn {key, value} ->
      "#{key}=#{quoted(to_string(value))}"
    end)
    |> Enum.join(", ")
  end

  defp vertex_id({:emit, workflow_name, event_name, index}) do
    "emit:#{workflow_name}:#{event_name}:#{index}"
  end

  defp vertex_id({:input, input_name}) do
    "input:#{input_name}"
  end

  defp vertex_id(value) when is_atom(value) do
    Atom.to_string(value)
  end

  defp vertex_id(value) do
    inspect(value)
  end

  defp quoted(value) do
    escaped =
      value
      |> to_string()
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")

    "\"#{escaped}\""
  end

  defp humanize(value) when is_atom(value) do
    value
    |> Atom.to_string()
    |> humanize_string()
  end

  defp humanize(value) when is_binary(value), do: humanize_string(value)
  defp humanize(value), do: inspect(value)

  defp humanize_string(value) do
    value
    |> String.replace("_", " ")
  end

  defp humanize_module(module) when is_atom(module) do
    module
    |> inspect()
    |> String.split(".")
    |> List.last()
  end

  defp sort_terms(values) do
    Enum.sort_by(values, &vertex_id/1)
  end

  defp indent(line), do: "  " <> line
  defp indent2(line), do: "    " <> line

  defp list(nil), do: []
  defp list(value) when is_list(value), do: value
  defp list(value), do: [value]
end
