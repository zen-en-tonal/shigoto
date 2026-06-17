# Persistence

Shigoto separates domain logic from persistence. Domain functions produce
*domain-valid change values* — changesets or maps of changesets. The executor
collects these into an `Ecto.Multi` that the caller commits as a single
transaction.

## The `persists` field

Declare which produced values should become DB operations:

```elixir
workflow do
  task :reserve_room do
    call {MyApp.Rooms, :reserve, [:rooms, :customer_id]}
    produces :reservation        # returns a changeset or map of changesets
  end

  persists [:reservation]        # collected into the returned Ecto.Multi
end
```

After execution:

```elixir
{:ok, ctx, persist_multi, _emits} = Shigoto.Executor.run(...)
{:ok, _} = MyApp.Repo.transaction(persist_multi)
```

`persist_multi` is an `Ecto.Multi` built from each declared value:

| Value type | Operation |
|---|---|
| `%Ecto.Changeset{data: %_{__meta__: %{state: :built}}}` | `Ecto.Multi.insert/3` |
| `%Ecto.Changeset{}` (loaded state) | `Ecto.Multi.update/3` |
| `%{name => changeset, ...}` (plain map) | Each entry expanded recursively |
| `[changeset, ...]` (list) | Each entry expanded with indexed op keys |
| Any other value | Skipped — no DB operation |

Values produced by skipped nodes (non-taken decision branches) are never added
to `persist_multi`.

## Maps and lists of changesets

When a task produces multiple related changesets, return a plain map keyed by
semantic name. The executor expands it into named `Ecto.Multi` operations:

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

    %{room: room_cs, history: history_cs}
  end
end
```

### Composing changeset maps

Use standard map operations to chain domain functions that pass changeset maps:

```elixir
def reserve(%{room: _} = changes, customer_id) do
  room = Ecto.Changeset.apply_changes(changes.room)
  Map.merge(changes, reserve(room, customer_id))
end
```

### Nested maps and lists

Maps and lists can be arbitrarily nested — the executor recurses into them:

```elixir
%{
  room: room_cs,                          # becomes op key :room
  extras: [amenity_cs, deposit_cs],       # becomes op keys {:extras, 0}, {:extras, 1}
  audit: %{before: before_cs, after: after_cs}  # becomes op keys :before, :after
}
```

Non-changeset entries in maps or lists are silently skipped.

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

By returning a changeset (or a map of changesets), the function remains a pure
data transformation. The caller — the Shigoto executor — decides when and how to
commit.

### Why use named maps instead of lists

A plain map is named. Each entry has a key that identifies what it represents
(`:room`, `:history`, `:invoice`). This makes `Ecto.Multi` operation keys
semantically meaningful — a failed operation identifies itself by name.

### Why persists are declared on the workflow, not the function

Domain functions don't know whether they're called inside a Shigoto workflow,
from a test, or from a script. Declaring `persists` on the workflow keeps the
"what gets committed" decision at the workflow specification level — where it
belongs as a business concern.

## Working with optimistic locking

Plain changeset maps work naturally with Ecto's optimistic locking:

```elixir
room_cs =
  room
  |> MyApp.Room.changeset(%{status: :reserved})
  |> Ecto.Changeset.optimistic_lock(:lock_version)

%{room: room_cs}
```

Ecto will verify the lock version when `Repo.transaction(persist_multi)` runs.
If another process updated the record between the domain call and the commit,
the transaction fails with `Ecto.StaleEntryError`.

## Testing persists

Because `Shigoto.Executor.run/4` returns the `Ecto.Multi` without committing it,
you can inspect it in tests without hitting the database:

```elixir
test "reserve produces an insert and a history update" do
  {:ok, ctx, persist_multi, _emits} =
    Shigoto.Executor.run(MyApp.Workflows.RoomReserve, :reserve_room, inputs)

  assert %{room: %Ecto.Changeset{}, history: %Ecto.Changeset{}} = ctx.reservation

  ops = Ecto.Multi.to_list(persist_multi)
  assert length(ops) == 2
end
```

To test the actual DB writes, wrap in `Ecto.Adapters.SQL.Sandbox`:

```elixir
test "reservation is committed" do
  {:ok, ctx, persist_multi, _emits} =
    Shigoto.Executor.run(MyApp.Workflows.RoomReserve, :reserve_room, inputs,
      repo: MyApp.Repo
    )

  assert {:ok, _} = MyApp.Repo.transaction(persist_multi)
  assert MyApp.Repo.get(MyApp.Room, ctx.reservation.room.changes.id)
end
```
