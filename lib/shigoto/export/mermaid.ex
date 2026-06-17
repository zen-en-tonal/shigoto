defmodule Shigoto.Export.Mermaid do
  @moduledoc """
  Exports Shigoto workflows as Mermaid flowcharts.

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

  The output is a Mermaid `flowchart` diagram.
  """

  @doc """
  Exports a workflow as a Mermaid flowchart.

  ## Options

    * `:direction` - Mermaid flowchart direction. Defaults to `"TD"`.
      Use `"LR"` for left-to-right diagrams.

    * `:rankdir` - DOT-compatible alias for `:direction`.
      Used only when `:direction` is not provided.

    * `:show_inputs?` - whether to render workflow inputs. Defaults to `false`.

    * `:show_technical_labels?` - whether to show internal edge labels.
      Defaults to `false`.

    * `:show_calls?` - whether to show MFA / workflow call details.
      Defaults to `false`.

    * `:show_map_edges?` - whether to show event payload mapping edges.
      Defaults to `false`.

    * `:title?` - whether to include the workflow title as a Mermaid comment.
      Defaults to `true`.

  ## Example

      Shigoto.Export.Mermaid.workflow(
        MyApp.Workflows.OrderApproval,
        :approve_order,
        direction: "LR"
      )

  """
  def workflow(module) when is_atom(module) do
    workflow(module, [])
  end

  def workflow(module, opts) when is_atom(module) and is_list(opts) do
    workflows = Shigoto.Info.workflows(module)

    case workflows do
      [single] -> workflow(module, single.name, opts)
      [] -> raise ArgumentError, "#{inspect(module)} has no workflows"
      _ -> raise ArgumentError, "#{inspect(module)} has multiple workflows; specify a workflow name"
    end
  end

  def workflow(module, workflow_name) when is_atom(module) and is_atom(workflow_name) do
    workflow(module, workflow_name, [])
  end

  def workflow(module, workflow_name, opts) do
    workflow = fetch_workflow!(module, workflow_name)
    automations = automations_for_workflow(module, workflow_name)
    graph = Shigoto.Graph.workflow_graph(workflow)

    direction =
      opts
      |> Keyword.get(:direction, Keyword.get(opts, :rankdir, "TD"))
      |> normalize_direction()

    show_inputs? = Keyword.get(opts, :show_inputs?, false)
    show_technical_labels? = Keyword.get(opts, :show_technical_labels?, false)
    show_calls? = Keyword.get(opts, :show_calls?, false)
    show_map_edges? = Keyword.get(opts, :show_map_edges?, false)
    title? = Keyword.get(opts, :title?, true)

    node_index = node_index(workflow)

    vertices =
      graph.vertices
      |> MapSet.to_list()
      |> sort_terms()

    business_edges =
      graph.edges
      |> Enum.filter(&business_edge?(&1, show_map_edges?))

    entry_vertices = entry_vertices(graph, business_edges)

    [
      "flowchart #{direction}",
      maybe_title(module, workflow, title?),
      "",
      class_defs(),
      "",
      automation_nodes_and_edges(module, workflow, automations),
      maybe_input_nodes(workflow, show_inputs?),
      workflow_subgraph(
        module,
        workflow,
        vertices,
        node_index,
        show_calls?
      ),
      start_edges(workflow, entry_vertices),
      maybe_input_edges(workflow, show_inputs?),
      edge_lines(business_edges, show_technical_labels?)
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

  defp maybe_title(_module, _workflow, false), do: nil

  defp maybe_title(module, workflow, true) do
    indent("%% #{workflow_title(module, workflow)}")
  end

  defp workflow_title(module, workflow) do
    "#{humanize_module(module)} / #{humanize(workflow.name)}"
  end

  defp workflow_subgraph(_module, workflow, vertices, node_index, show_calls?) do
    [
      indent("subgraph #{mermaid_id("cluster:#{workflow.name}")}[") <>
        mermaid_label("Workflow: #{humanize(workflow.name)}") <> "]",
      mermaid_node_raw(start_vertex(workflow),
        label: "開始",
        shape: "oval",
        class: "start"
      ),
      "",
      vertices
      |> Enum.map(fn vertex ->
        case Map.fetch(node_index, vertex) do
          {:ok, {:assert, assertion}} ->
            mermaid_node(vertex,
              label: assertion_label(assertion),
              shape: "hexagon",
              class: "assertion"
            )

          {:ok, {:task, task}} ->
            mermaid_node(vertex,
              label: task_label(task, show_calls?),
              shape: task_shape(task),
              class: "task"
            )

          {:ok, {:decision, decision}} ->
            mermaid_node(vertex,
              label: decision_label(decision),
              shape: "diamond",
              class: "decision"
            )

          {:ok, {:emit, {emit, _index}}} ->
            mermaid_node(vertex,
              label: emit_label(emit),
              shape: "ellipse",
              class: "event"
            )

          :error ->
            mermaid_node(vertex,
              label: humanize(vertex),
              shape: "box",
              class: "task"
            )
        end
      end),
      indent("end")
    ]
  end

  defp automation_nodes_and_edges(_module, _workflow, []), do: []

  defp automation_nodes_and_edges(_module, workflow, automations) do
    start_vertex = start_vertex(workflow)

    automations
    |> Enum.with_index()
    |> Enum.flat_map(fn {automation, index} ->
      automation_id = automation_vertex(automation, index)
      event_id = event_vertex(automation.on, index)

      [
        mermaid_node_raw(event_id,
          label: trigger_event_label(automation.on),
          shape: "ellipse",
          class: "event"
        ),
        mermaid_node_raw(automation_id,
          label: automation_label(automation),
          shape: "box",
          class: "automation"
        ),
        mermaid_edge_raw(event_id, automation_id, label: "トリガー"),
        mermaid_edge_raw(automation_id, start_vertex, label: "開始")
      ]
    end)
  end

  defp start_edges(workflow, entry_vertices) do
    start_vertex = start_vertex(workflow)

    entry_vertices
    |> Enum.map(fn entry ->
      mermaid_edge_raw(start_vertex, vertex_id(entry), [])
    end)
  end

  defp maybe_input_nodes(_workflow, false), do: []

  defp maybe_input_nodes(workflow, true) do
    workflow.inputs
    |> list()
    |> Enum.map(fn input ->
      mermaid_node(input_vertex(input.name),
        label: "#{humanize(input.name)}\n#{input.type}",
        shape: "parallelogram",
        class: "input"
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
        mermaid_edge(input_vertex(input_name), target_vertex, style: "dashed")
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
      mermaid_edge(edge.from, edge.to, attrs)
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

    entries = MapSet.difference(vertices, incoming)

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

  defp format_mfa({module, function, arg_spec})
       when is_atom(module) and is_atom(function) and is_list(arg_spec) do
    args = arg_spec |> Enum.map(&inspect/1) |> Enum.join(", ")
    "#{inspect(module)}.#{function}(#{args})"
  end

  defp format_mfa(other), do: inspect(other)

  defp format_workflow_ref(name) when is_atom(name), do: Atom.to_string(name)

  defp format_workflow_ref({module, name}) when is_atom(module) and is_atom(name) do
    "#{inspect(module)}.#{name}"
  end

  defp format_workflow_ref({module, name, _args}) when is_atom(module) and is_atom(name) do
    "#{inspect(module)}.#{name}"
  end

  defp format_workflow_ref(other), do: inspect(other)

  defp start_vertex(workflow), do: "workflow_start:#{workflow.name}"

  defp input_vertex(input_name), do: {:input, input_name}

  defp automation_vertex(automation, index) do
    "automation:#{automation.name}:#{index}"
  end

  defp event_vertex(event, index) do
    "trigger_event:#{inspect(event)}:#{index}"
  end

  defp mermaid_node(vertex, attrs) do
    mermaid_node_raw(vertex_id(vertex), attrs)
  end

  defp mermaid_node_raw(id_key, attrs) do
    label = attrs |> Keyword.fetch!(:label) |> mermaid_label()
    shape = Keyword.get(attrs, :shape, "box")
    class = Keyword.get(attrs, :class)

    indent("#{mermaid_id(id_key)}#{mermaid_shape(label, shape)}#{class_suffix(class)}")
  end

  defp mermaid_edge(_from, _to, []), do: nil

  defp mermaid_edge(from, to, attrs) do
    mermaid_edge_raw(vertex_id(from), vertex_id(to), attrs)
  end

  defp mermaid_edge_raw(from, to, attrs) do
    from_id = mermaid_id(from)
    to_id = mermaid_id(to)
    style = Keyword.get(attrs, :style, "solid")
    label = Keyword.get(attrs, :label)
    arrow = mermaid_arrow(style)

    edge =
      if is_nil(label) do
        "#{from_id} #{arrow} #{to_id}"
      else
        "#{from_id} #{arrow}|#{mermaid_edge_label(label)}| #{to_id}"
      end

    indent(edge)
  end

  defp mermaid_shape(label, "diamond"), do: "{#{label}}"
  defp mermaid_shape(label, "hexagon"), do: "{{#{label}}}"
  defp mermaid_shape(label, "ellipse"), do: "((#{label}))"
  defp mermaid_shape(label, "oval"), do: "([#{label}])"
  defp mermaid_shape(label, "parallelogram"), do: "[/#{label}/]"
  defp mermaid_shape(label, "component"), do: "[[#{label}]]"
  defp mermaid_shape(label, _shape), do: "[#{label}]"

  defp mermaid_arrow("bold"), do: "==>"
  defp mermaid_arrow("dashed"), do: "-.->"
  defp mermaid_arrow("dotted"), do: "-.->"
  defp mermaid_arrow(_style), do: "-->"

  defp class_suffix(nil), do: ""
  defp class_suffix(class), do: ":::#{class}"

  defp class_defs do
    [
      indent("classDef start fill:#f5f5f5,stroke:#999,stroke-width:1px;"),
      indent("classDef automation fill:#f8f8f8,stroke:#999,stroke-width:1px;"),
      indent("classDef input fill:#fff,stroke:#999,stroke-dasharray:3 3;"),
      indent("classDef assertion fill:#f8f8f8,stroke:#999,stroke-width:1px;"),
      indent("classDef task fill:#fff,stroke:#555,stroke-width:1px;"),
      indent("classDef decision fill:#fff,stroke:#555,stroke-width:1px;"),
      indent("classDef event fill:#fff,stroke:#777,stroke-width:1px;")
    ]
  end

  defp mermaid_id(value) do
    raw = to_string(value)

    base =
      raw
      |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
      |> String.trim("_")
      |> String.slice(0, 48)

    hash =
      :crypto.hash(:sha256, raw)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 10)

    case base do
      "" -> "n_#{hash}"
      base -> "n_#{base}_#{hash}"
    end
  end

  defp mermaid_label(value) do
    escaped =
      value
      |> to_string()
      |> String.replace("&", "&amp;")
      |> String.replace("\"", "&quot;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")
      |> String.replace("\n", "<br/>")

    "\"#{escaped}\""
  end

  defp mermaid_edge_label(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("|", "&#124;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\n", " ")
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

  defp normalize_direction("TB"), do: "TD"
  defp normalize_direction("BT"), do: "BT"
  defp normalize_direction("LR"), do: "LR"
  defp normalize_direction("RL"), do: "RL"
  defp normalize_direction("TD"), do: "TD"
  defp normalize_direction(_direction), do: "TD"

  defp sort_terms(values) do
    Enum.sort_by(values, &vertex_id/1)
  end

  defp indent(line), do: "  " <> line

  defp list(nil), do: []
  defp list(value) when is_list(value), do: value
  defp list(value), do: [value]
end
