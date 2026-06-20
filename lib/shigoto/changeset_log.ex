if Code.ensure_loaded?(Ecto.Multi) do
  defmodule Shigoto.ChangesetLog do
    @moduledoc """
    An ordered sequence of changesets that can be replayed into the current Entity.

    Rather than discarding change information via `Ecto.Changeset.apply_changes/1`,
    domain functions can accumulate changesets into a `ChangesetLog`. Each changeset
    is stored directly — all Ecto directives (`changes`, `prepare`, `repo_opts`,
    `filters`, `constraints`) are preserved with zero transformation.

    The current entity is derived by projecting (replaying) the log — it is not
    stored as a separate value.

    ## Usage

        def process_room(room, customer_id) do
          cs1 = room |> MyApp.Room.reserve(%{customer_id: customer_id, status: :reserved})
          log  = Shigoto.ChangesetLog.append(cs1, domain_op: :reserve)

          history_cs = %MyApp.Room.History{room_id: room.id} |> MyApp.Room.History.changeset(%{status: :reserved})
          log = Shigoto.ChangesetLog.append(log, history_cs, domain_op: :log_history)

          current = Shigoto.ChangesetLog.project(log, room)
          log
        end

    The log can be returned as a task's `produces` value and listed in `persists`.
    `Shigoto.Executor` expands it into indexed `Ecto.Multi` operations automatically.
    """

    defstruct initial: %{}, entries: []

    @type entry :: %{
            required(:changeset) => Ecto.Changeset.t(),
            optional(:domain_op) => atom() | nil,
            optional(:applied_at) => DateTime.t() | nil,
            optional(:metadata) => map()
          }

    @type t :: %__MODULE__{
            initial: %{module() => struct()},
            entries: [entry()]
          }

    @doc """
    Creates a log from the first changeset.

    `cs.data` is registered as the persistence anchor for its schema — later
    changesets for the same schema do not overwrite this anchor, so the original
    loaded entity (with primary key) is preserved for update operations.

    ## Options

      * `:domain_op` — atom naming the domain function that produced this changeset
      * `:applied_at` — `DateTime.t()` (defaults to `DateTime.utc_now()`)
      * `:metadata` — arbitrary map for caller-defined provenance
    """
    @spec append(Ecto.Changeset.t()) :: t()
    def append(%Ecto.Changeset{} = cs), do: append(%__MODULE__{}, cs, [])

    @spec append(Ecto.Changeset.t(), keyword()) :: t()
    def append(%Ecto.Changeset{} = cs, opts) when is_list(opts), do: append(%__MODULE__{}, cs, opts)

    @doc """
    Appends a changeset to an existing log.

    If this is the first changeset for a schema, `cs.data` is registered as the
    persistence anchor for that schema in `log.initial`.
    """
    @spec append(t(), Ecto.Changeset.t()) :: t()
    def append(%__MODULE__{} = log, %Ecto.Changeset{} = cs), do: append(log, cs, [])

    @spec append(t(), Ecto.Changeset.t(), keyword()) :: t()
    def append(%__MODULE__{} = log, %Ecto.Changeset{} = cs, opts) do
      entry = %{
        changeset: cs,
        domain_op: opts[:domain_op],
        applied_at: opts[:applied_at] || DateTime.utc_now(),
        metadata: opts[:metadata] || %{}
      }

      initial = Map.put_new(log.initial, cs.data.__struct__, cs.data)
      %{log | initial: initial, entries: log.entries ++ [entry]}
    end

    @doc """
    Replays all entries matching `base.__struct__` onto `base` and returns the
    current entity.

    Entries for other schemas in the log are ignored. The same log can be
    projected onto different base entities.

        current_room = Shigoto.ChangesetLog.project(log, loaded_room)
    """
    @spec project(t(), struct()) :: struct()
    def project(%__MODULE__{entries: entries}, %_{} = base) do
      schema = base.__struct__

      entries
      |> Enum.filter(&(&1.changeset.data.__struct__ == schema))
      |> Enum.reduce(base, fn entry, entity ->
        entity
        |> Ecto.Changeset.change(entry.changeset.changes)
        |> Ecto.Changeset.apply_changes()
      end)
    end

    @doc """
    Projects all schemas in the log onto their stored `initial` entities and
    returns a map of `%{schema_module => current_entity}`.

        %{MyApp.Room => current_room, MyApp.Room.History => current_history} =
          Shigoto.ChangesetLog.project(log)
    """
    @spec project(t()) :: %{module() => struct()}
    def project(%__MODULE__{initial: initial} = log) do
      Map.new(initial, fn {_schema, base} -> {base.__struct__, project(log, base)} end)
    end

    @doc """
    Projects the log to the current entity, calls `fun` with it, and folds the
    returned changeset(s) back into the log.

    `fun` is a pure domain function that receives the current entity and returns
    one of:
    - `%Ecto.Changeset{}`
    - `[%Ecto.Changeset{}]`
    - `[{atom(), %Ecto.Changeset{}}]` — keyword list; atom is used as `domain_op`

    ## Example

        log = ChangesetLog.apply(log, loaded_room, fn room ->
          MyApp.Room.reserve(room, customer_id)
        end)
    """
    @spec apply(
            t(),
            struct(),
            (struct() ->
               Ecto.Changeset.t() | [Ecto.Changeset.t()] | [{atom(), Ecto.Changeset.t()}])
          ) :: t()
    def apply(%__MODULE__{} = log, %_{} = base, fun) when is_function(fun, 1) do
      log |> project(base) |> fun.() |> fold_into(log)
    end

    @doc """
    Returns the stored changesets in order.

    Each changeset carries the `__meta__.state` it had when appended:
    - `:built` → `Ecto.Multi.insert`
    - `:loaded` → `Ecto.Multi.update`

    Used by `Shigoto.Executor` for persistence. Prefer `project/2` when you only
    need the current entity state.
    """
    @spec to_changesets(t()) :: [Ecto.Changeset.t()]
    def to_changesets(%__MODULE__{entries: entries}) do
      Enum.map(entries, & &1.changeset)
    end

    defp fold_into(%Ecto.Changeset{} = cs, log), do: append(log, cs)

    defp fold_into(results, log) when is_list(results) do
      Enum.reduce(results, log, fn
        {key, %Ecto.Changeset{} = cs}, acc -> append(acc, cs, domain_op: key)
        %Ecto.Changeset{} = cs, acc -> append(acc, cs)
      end)
    end
  end
end
