# Persistence

Shigoto separates domain logic from persistence. Domain functions produce
*domain-valid change values* — changesets or `ChangesetMulti` structs. The
executor collects these into an `Ecto.Multi` that the caller commits as a
single transaction.

## The `persists` field

Declare which produced values should become DB operations:

```elixir
workflow do
  task :reserve_room do
    call {MyApp.Rooms, :reserve, [:rooms, :customer_id]}
    produces :reservation        # returns a changeset or ChangesetMulti
  end

  persists [:reservation]        # collected into the returned Ecto.Multi
end
```

After execution:

```elixir
{:ok, ctx, persist_multi} = Shigoto.Executor.run(...)
{:ok, _} = MyApp.Repo.transaction(persist_multi)
```

`persist_multi` is an `Ecto.Multi` built from each declared value:

| Value type | Operation |
|---|---|
| `%Ecto.Changeset{data: %_{__meta__: %{state: :built}}}` | `Ecto.Multi.insert/3` |
| `%Ecto.Changeset{}` (loaded state) | `Ecto.Multi.update/3` |
| `%Shigoto.Ecto.ChangesetMulti{}` | Merged via `Ecto.Multi.merge/2` |
| Any other value | Skipped — no DB operation |

Values produced by skipped nodes (non-taken decision branches) are never added
to `persist_multi`.

## `Shigoto.Ecto.ChangesetMulti`

A `ChangesetMulti` bundles multiple named changesets into a single domain-layer
value. Domain functions produce it; the executor converts it into DB operations.

### Creating one

```elixir
defmodule MyApp.Rooms do
  def reserve(%{available: true, suggested: room}, customer_id) do
    room_cs =
      room
      |> MyApp.Room.changeset(%{status: :reserved, customer_id: customer_id})
      |> Ecto.Changeset.optimistic_lock(:updated_at)

    history_cs =
      %MyApp.Room.History{room_id: room.id}
      |> MyApp.Room.History.changeset(%{status: :reserved})

    Shigoto.Ecto.ChangesetMulti.new(%{
      room: room_cs,
      history: history_cs,
    })
  end
end
```

### Composing with `flat_map/3`

Chain domain functions that each accept and return changeset-like values:

```elixir
def reserve(%Shigoto.Ecto.ChangesetMulti{} = multi, customer_id) do
  Shigoto.Ecto.ChangesetMulti.flat_map(multi, :room, fn room ->
    # room is the result of Ecto.Changeset.apply_changes on the :room entry
    reserve(room, customer_id)
  end)
end
```

`flat_map/3` extracts the entry at `key`, applies changesets before passing them
to `fun`, and merges the returned `ChangesetMulti` back. The function must return
a `ChangesetMulti`.

### Converting to `Ecto.Multi`

The executor calls `to_multi/1` automatically for values listed in `persists`.
You can also call it directly:

```elixir
multi = Shigoto.Ecto.ChangesetMulti.to_multi(changeset_multi)
{:ok, _} = MyApp.Repo.transaction(multi)
```

Each entry is inserted or updated based on the schema record's `__meta__.state`:
- `:built` → `Ecto.Multi.insert`
- `:loaded` → `Ecto.Multi.update`

Nested `ChangesetMulti` entries are converted recursively.

## Sub-workflow persists

When a task calls a sub-workflow, the sub-workflow's `persist_multi` is merged
into the parent's automatically. The entire call tree is covered by one
transaction:

```elixir
# Inner workflow
workflow :reserve_room do
  task :reserve do
    call {MyApp.Rooms, :reserve, [:rooms, :customer_id]}
    produces :reservation
  end
  persists [:reservation]
end

# Outer workflow
workflow :book_order do
  task :run_room_reserve do
    workflow {MyApp.Workflows.RoomReserve, :reserve_room}
    requires [:rooms, :customer_id]
    produces :room_result
  end
end

# Both :reservation (from inner) lands in the returned persist_multi
{:ok, ctx, persist_multi} = Shigoto.Executor.run(MyApp.Workflows.BookOrder, :book_order, ...)
{:ok, _} = MyApp.Repo.transaction(persist_multi)
```

## Design rationale

### Why domain functions return changesets instead of persisting

When a domain function calls `repo.insert` or `repo.update` directly, it becomes
impossible to:

1. Compose multiple domain operations into a single atomic transaction.
2. Test domain logic without a real database connection.
3. Review what will be persisted before committing.

By returning a changeset (or `ChangesetMulti`), the function remains a pure
data transformation. The caller — the Shigoto executor — decides when and how to
commit.

### Why `ChangesetMulti` instead of a plain list

A `ChangesetMulti` is named. Each changeset entry has a key that identifies what
it represents (`:room`, `:history`, `:invoice`). This makes composition via
`flat_map` explicit: you say which entry you're transforming, not which index.

It also makes debugging easier — `Ecto.Multi` operation keys are derived from
the entry names, so failed operations identify themselves semantically.

### Why persists are declared on the workflow, not the function

Domain functions don't know whether they're called inside a Shigoto workflow,
from a test, or from a script. Declaring `persists` on the workflow keeps the
"what gets committed" decision at the workflow specification level — where it
belongs as a business concern.

## Working with optimistic locking

`ChangesetMulti` works naturally with Ecto's optimistic locking:

```elixir
room_cs =
  room
  |> MyApp.Room.changeset(%{status: :reserved})
  |> Ecto.Changeset.optimistic_lock(:lock_version)

Shigoto.Ecto.ChangesetMulti.new(%{room: room_cs})
```

Ecto will verify the lock version when `Repo.transaction(persist_multi)` runs.
If another process updated the record between the domain call and the commit,
the transaction fails with `Ecto.StaleEntryError`.

## Testing persists

Because `Shigoto.Executor.run/4` returns the `Ecto.Multi` without committing it,
you can inspect it in tests without hitting the database:

```elixir
test "reserve produces an insert and a history update" do
  {:ok, ctx, persist_multi} =
    Shigoto.Executor.run(MyApp.Workflows.RoomReserve, :reserve_room, inputs)

  assert %Shigoto.Ecto.ChangesetMulti{} = ctx.reservation

  ops = Ecto.Multi.to_list(persist_multi)
  assert length(ops) == 2
end
```

To test the actual DB writes, wrap in `Ecto.Adapters.SQL.Sandbox`:

```elixir
test "reservation is committed" do
  {:ok, ctx, persist_multi} =
    Shigoto.Executor.run(MyApp.Workflows.RoomReserve, :reserve_room, inputs,
      repo: MyApp.Repo
    )

  assert {:ok, _} = MyApp.Repo.transaction(persist_multi)
  assert MyApp.Repo.get(MyApp.Room, ctx.reservation.entries.room.changes.id)
end
```
