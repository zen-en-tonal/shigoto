if Code.ensure_loaded?(Ecto.Multi) do
  defmodule Shigoto.Ecto.ChangesetMulti do
    @moduledoc """
    A domain-layer value representing domain-valid changes across multiple
    persistence targets.

    Where `Ecto.Changeset` represents a single domain-valid change,
    `ChangesetMulti` bundles several named changesets into one cohesive unit
    that can be passed between domain functions and later converted to an
    `Ecto.Multi` for transactional persistence.

    Domain functions produce `ChangesetMulti` values; they do not interact
    with `Ecto.Multi` or the database directly. The Shigoto workflow runtime
    (via `Shigoto.Multi`) converts declared `persists` values into DB
    operations at the end of each workflow transaction.

    ## Example

        # Domain function producing a ChangesetMulti
        def reserve(%{available: true, suggested: room}, customer_id) do
          room_cs = Room.changeset(room, %{status: :reserved, customer_id: customer_id})
          history_cs = Room.History.changeset(%Room.History{}, %{room_id: room.id, status: :reserved})

          Shigoto.Ecto.ChangesetMulti.new(%{
            room: room_cs,
            history: history_cs
          })
        end

        # Domain function accepting a ChangesetMulti (pipeline composition)
        def reserve(%Shigoto.Ecto.ChangesetMulti{} = multi, customer_id) do
          Shigoto.Ecto.ChangesetMulti.flat_map(multi, :room, fn room ->
            reserve(room, customer_id)
          end)
        end

    """

    @type entry :: Ecto.Changeset.t() | t() | term()

    @type t :: %__MODULE__{
            entries: %{atom() => entry()}
          }

    defstruct entries: %{}

    @doc """
    Creates a `ChangesetMulti` from a map of named entries.

    Entries are typically `Ecto.Changeset` values, but may also be nested
    `ChangesetMulti` structs or plain values.
    """
    @spec new(%{atom() => entry()}) :: t()
    def new(entries) when is_map(entries) do
      %__MODULE__{entries: entries}
    end

    @doc """
    Returns the entry stored under `key`, raising `KeyError` if absent.
    """
    @spec fetch!(t(), atom()) :: entry()
    def fetch!(%__MODULE__{entries: entries}, key) do
      Map.fetch!(entries, key)
    end

    @doc """
    Transforms the entry at `key` and merges the result back.

    The entry is extracted and, if it is an `Ecto.Changeset`, its changes are
    applied before being passed to `fun`. `fun` must return a `ChangesetMulti`.
    Its entries are merged over the original entries (function result wins on
    key conflicts), and the combined `ChangesetMulti` is returned.

    Useful for chaining domain functions that each accept and return
    changeset-like values.
    """
    @spec flat_map(t(), atom(), (term() -> t())) :: t()
    def flat_map(%__MODULE__{entries: entries}, key, fun) do
      value = Map.fetch!(entries, key)
      applied = apply_entry(value)

      case fun.(applied) do
        %__MODULE__{entries: new_entries} ->
          %__MODULE__{entries: Map.merge(entries, new_entries)}

        other ->
          raise ArgumentError,
                "Shigoto.Ecto.ChangesetMulti.flat_map/3 function must return a ChangesetMulti, got: #{inspect(other)}"
      end
    end

    @doc """
    Converts this `ChangesetMulti` to an `Ecto.Multi` for transactional
    persistence.

    Each entry is inserted or updated based on the underlying schema record's
    persistence state (`__meta__.state`):

      * `:built` → `Ecto.Multi.insert/3`
      * `:loaded` → `Ecto.Multi.update/3`

    Nested `ChangesetMulti` entries are converted recursively via
    `Ecto.Multi.merge/2`.

    Non-changeset entries (plain structs, maps, nil) are silently skipped.

    `prefix` is used internally by `Shigoto.Multi` to scope operation keys
    and avoid collisions. Pass `[]` (default) when calling outside the Shigoto
    runtime.
    """
    @spec to_multi(t(), list()) :: Ecto.Multi.t()
    def to_multi(%__MODULE__{entries: entries}, prefix \\ []) do
      Enum.reduce(entries, Ecto.Multi.new(), fn {name, entry}, m ->
        op = if prefix == [], do: name, else: {:shigoto_persist, prefix, name}

        case entry do
          %Ecto.Changeset{data: %_{__meta__: %{state: :built}}} ->
            Ecto.Multi.insert(m, op, entry)

          %Ecto.Changeset{} ->
            Ecto.Multi.update(m, op, entry)

          %__MODULE__{} = nested ->
            Ecto.Multi.merge(m, fn _ -> to_multi(nested, prefix ++ [name]) end)

          _ ->
            m
        end
      end)
    end

    defp apply_entry(%Ecto.Changeset{} = cs), do: Ecto.Changeset.apply_changes(cs)
    defp apply_entry(value), do: value
  end
end
