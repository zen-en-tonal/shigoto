defmodule Shigoto.Graph do
  @moduledoc """
  Builds dependency graphs from Shigoto workflow definitions.

  This module does not execute workflows.
  It only converts workflow DSL structs into graph data that can be used for
  validation, documentation, visualization, and cycle detection.
  """

  defstruct [
    :workflow,
    vertices: MapSet.new(),
    edges: []
  ]

  defmodule Edge do
    @moduledoc """
    Directed edge in a workflow graph.
    """

    defstruct [
      :from,
      :to,
      :kind,
      :label,
      :source
    ]
  end

  @type vertex :: atom() | tuple()

  @type edge :: %Edge{
          from: vertex(),
          to: vertex(),
          kind: atom(),
          label: term(),
          source: term()
        }

  @type t :: %__MODULE__{
          workflow: atom(),
          vertices: MapSet.t(vertex()),
          edges: [edge()]
        }

  @doc """
  Builds a workflow-local dependency graph.

  Vertices include:

    * assertions
    * tasks
    * decisions
    * emits

  Edges are derived from:

    * `after`
    * `requires`
    * `decision.branches`
    * `emit.map from: ...`

  Inputs are not graph vertices.
  They are external values, so `requires: [:input_name]` does not create an edge.

  Produced values are resolved into producer nodes.
  For example, if `:load_order` produces `:order`, then a task requiring `:order`
  gets an edge from `:load_order`.
  """
  @spec workflow_graph(struct()) :: t()
  def workflow_graph(workflow) do
    vertices = workflow_vertices(workflow)
    producer_by_value = producer_by_value(workflow)

    edges =
      []
      |> Kernel.++(after_edges(workflow))
      |> Kernel.++(requires_edges(workflow, producer_by_value))
      |> Kernel.++(branch_edges(workflow))
      |> Kernel.++(emit_mapping_edges(workflow, producer_by_value))

    %__MODULE__{
      workflow: workflow.name,
      vertices: MapSet.new(vertices),
      edges: edges
    }
  end

  def workflow_graph(mod, name) do
    Shigoto.Info.workflows(mod)
    |> Enum.find(&(&1.name == name))
    |> workflow_graph()
  end

  @doc """
  Runs a function with a temporary `:digraph`.

  The digraph is always deleted after the function returns or raises.

  Use this instead of returning a raw `:digraph` unless the caller really wants
  to manage its lifecycle manually.
  """
  @spec with_digraph(t(), (:digraph.graph() -> result)) :: result when result: term()
  def with_digraph(%__MODULE__{} = graph, fun) when is_function(fun, 1) do
    digraph = to_digraph(graph)

    try do
      fun.(digraph)
    after
      :digraph.delete(digraph)
    end
  end

  @doc """
  Builds an Erlang `:digraph` from a Shigoto graph.

  The caller is responsible for deleting the returned graph with
  `:digraph.delete/1`.

  Most callers should prefer `with_digraph/2`.
  """
  @spec to_digraph(t()) :: :digraph.graph()
  def to_digraph(%__MODULE__{} = graph) do
    digraph = :digraph.new([:cyclic, :private])

    Enum.each(graph.vertices, fn vertex ->
      :digraph.add_vertex(digraph, vertex)
    end)

    Enum.each(graph.edges, fn %Edge{} = edge ->
      :digraph.add_vertex(digraph, edge.from)
      :digraph.add_vertex(digraph, edge.to)
      :digraph.add_edge(digraph, make_ref(), edge.from, edge.to, edge)
    end)

    digraph
  end

  @doc """
  Returns `{:ok, topsort}` if the workflow graph is acyclic.

  Returns `{:error, message}` if a cycle exists.
  """
  @spec validate_acyclic(t(), String.t() | nil) :: {:ok, [vertex()]} | {:error, String.t()}
  def validate_acyclic(%__MODULE__{} = graph, context \\ nil) do
    with_digraph(graph, fn digraph ->
      case :digraph_utils.topsort(digraph) do
        false ->
          {:error, cycle_message(graph, digraph, context)}

        topsort ->
          {:ok, topsort}
      end
    end)
  end

  @doc """
  Returns `true` if the workflow graph has no cycles.
  """
  @spec acyclic?(t()) :: boolean()
  def acyclic?(%__MODULE__{} = graph) do
    match?({:ok, _}, validate_acyclic(graph))
  end

  @doc """
  Returns graph edges as simple `{from, to, kind}` tuples.

  Useful for tests and quick inspection.
  """
  @spec edge_tuples(t()) :: [{vertex(), vertex(), atom()}]
  def edge_tuples(%__MODULE__{} = graph) do
    Enum.map(graph.edges, fn %Edge{from: from, to: to, kind: kind} ->
      {from, to, kind}
    end)
  end

  defp workflow_vertices(workflow) do
    assertion_vertices =
      workflow.assertions
      |> list()
      |> Enum.map(& &1.name)

    task_vertices =
      workflow.tasks
      |> list()
      |> Enum.map(& &1.name)

    decision_vertices =
      workflow.decisions
      |> list()
      |> Enum.map(& &1.name)

    emit_vertices =
      workflow.emits
      |> list()
      |> Enum.with_index()
      |> Enum.map(fn {emit, index} ->
        emit_vertex(workflow, emit, index)
      end)

    assertion_vertices ++ task_vertices ++ decision_vertices ++ emit_vertices
  end

  defp after_edges(workflow) do
    []
    |> Kernel.++(
      workflow.assertions
      |> list()
      |> Enum.flat_map(fn assertion ->
        after_edges_for(workflow, assertion.name, assertion, :assert)
      end)
    )
    |> Kernel.++(
      workflow.tasks
      |> list()
      |> Enum.flat_map(fn task ->
        after_edges_for(workflow, task.name, task, :task)
      end)
    )
    |> Kernel.++(
      workflow.decisions
      |> list()
      |> Enum.flat_map(fn decision ->
        after_edges_for(workflow, decision.name, decision, :decision)
      end)
    )
    |> Kernel.++(
      workflow.emits
      |> list()
      |> Enum.with_index()
      |> Enum.flat_map(fn {emit, index} ->
        after_edges_for(workflow, emit_vertex(workflow, emit, index), emit, :emit)
      end)
    )
  end

  defp after_edges_for(_workflow, to, node, kind) do
    node
    |> Map.get(:after_nodes, [])
    |> list()
    |> Enum.map(fn predecessor ->
      %Edge{
        from: predecessor,
        to: to,
        kind: :after,
        label: nil,
        source: {kind, Map.get(node, :name) || Map.get(node, :event)}
      }
    end)
  end

  defp requires_edges(workflow, producer_by_value) do
    []
    |> Kernel.++(
      workflow.assertions
      |> list()
      |> Enum.flat_map(fn assertion ->
        requires_edges_for(assertion.name, assertion, producer_by_value, :assert)
      end)
    )
    |> Kernel.++(
      workflow.tasks
      |> list()
      |> Enum.flat_map(fn task ->
        requires_edges_for(task.name, task, producer_by_value, :task)
      end)
    )
    |> Kernel.++(
      workflow.decisions
      |> list()
      |> Enum.flat_map(fn decision ->
        requires_edges_for(decision.name, decision, producer_by_value, :decision)
      end)
    )
  end

  defp requires_edges_for(to, node, producer_by_value, kind) do
    node
    |> Map.get(:requires, [])
    |> list()
    |> Enum.flat_map(fn value ->
      case Map.fetch(producer_by_value, value) do
        {:ok, producer} ->
          [
            %Edge{
              from: producer,
              to: to,
              kind: :requires,
              label: value,
              source: {kind, node.name}
            }
          ]

        :error ->
          []
      end
    end)
  end

  defp branch_edges(workflow) do
    workflow.decisions
    |> list()
    |> Enum.flat_map(fn decision ->
      decision.branches
      |> list()
      |> Enum.map(fn {branch, target} ->
        %Edge{
          from: decision.name,
          to: target,
          kind: :branch,
          label: branch,
          source: {:decision, decision.name}
        }
      end)
    end)
  end

  defp emit_mapping_edges(workflow, producer_by_value) do
    workflow.emits
    |> list()
    |> Enum.with_index()
    |> Enum.flat_map(fn {emit, index} ->
      emit_id = emit_vertex(workflow, emit, index)

      emit.mappings
      |> list()
      |> Enum.flat_map(fn mapping ->
        with {:ok, value} <- source_root(mapping.from),
             {:ok, producer} <- Map.fetch(producer_by_value, value) do
          [
            %Edge{
              from: producer,
              to: emit_id,
              kind: :map,
              label: value,
              source: {:emit, emit.event}
            }
          ]
        else
          _ -> []
        end
      end)
    end)
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

  defp emit_vertex(workflow, emit, index) do
    {:emit, workflow.name, emit.event, index}
  end

  defp source_root([root | _]) when is_atom(root), do: {:ok, root}
  defp source_root(_), do: :error

  defp cycle_message(graph, digraph, context) do
    components =
      digraph
      |> cyclic_components()
      |> Enum.map(&inspect/1)
      |> Enum.join(", ")

    prefix =
      case context do
        nil -> "Cycle detected in workflow #{inspect(graph.workflow)}"
        context -> "Cycle detected in #{context}"
      end

    if components == "" do
      prefix
    else
      "#{prefix}: #{components}"
    end
  end

  defp cyclic_components(digraph) do
    digraph
    |> :digraph_utils.strong_components()
    |> Enum.filter(fn
      [_single] = component ->
        self_loop?(digraph, hd(component))

      component ->
        length(component) > 1
    end)
  end

  defp self_loop?(digraph, vertex) do
    digraph
    |> :digraph.out_edges(vertex)
    |> Enum.any?(fn edge_id ->
      case :digraph.edge(digraph, edge_id) do
        {_edge_id, ^vertex, ^vertex, _label} -> true
        _ -> false
      end
    end)
  end

  defp list(nil), do: []
  defp list(value) when is_list(value), do: value
  defp list(value), do: [value]
end
