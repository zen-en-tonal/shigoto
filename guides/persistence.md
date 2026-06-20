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
| `%Shigoto.ChangesetLog{}` | Each entry expanded with indexed op keys `{key, 0}`, `{key, 1}`, … |
| `%{name => changeset, ...}` (plain map) | Each entry expanded recursively |
| `[changeset, ...]` (list) | Each entry expanded with indexed op keys |
| Any other value | Skipped — no DB operation |

Values produced by skipped nodes (non-taken decision branches) are never added
to `persist_multi`.

## `Shigoto.ChangesetLog`

`Shigoto.ChangesetLog` is the primary abstraction for accumulating multiple
changesets — potentially across different schemas — during a single workflow step.
Each changeset is stored directly; all Ecto directives (`prepare`, `repo_opts`,
`filters`, `constraints`, optimistic locks) are preserved with zero transformation.

### Basic usage

```elixir
defmodule MyApp.Rooms do
  def reserve(%{available: true, suggested: room}, customer_id) do
    room_cs =
      room
      |> MyApp.Room.changeset(%{status: :reserved, customer_id: customer_id})
      |> Ecto.Changeset.optimistic_lock(:version)

    history_cs =
      %MyApp.Room.History{room_id: room.id}
      |> MyApp.Room.History.changeset(%{status: :reserved})

    room_cs
    |> Shigoto.ChangesetLog.append(domain_op: :reserve)
    |> Shigoto.ChangesetLog.append(history_cs, domain_op: :log_history)
  end
end
```

The first call to `append/1-2` creates the log. The second call appends to it.
`cs.data` is registered as the persistence anchor for its schema on first
encounter — later changesets for the same schema do not overwrite it, so the
original loaded entity (with primary key) is preserved for update operations.

### Chaining with `apply/3`

`apply/3` is a shorthand for the project → domain function → fold-back pattern:

```elixir
def reserve(%Shigoto.ChangesetLog{} = log, customer_id) do
  Shigoto.ChangesetLog.apply(log, %MyApp.Room{}, fn current_room ->
    reserve(current_room, customer_id)
  end)
end
```

`apply/3` projects the log onto the base entity (replaying only entries for that
schema), passes the result to the function, and folds the returned changeset(s)
back into the log. The function may return a single `Ecto.Changeset`, a list, or
a keyword list `[{atom, changeset}]` where the key becomes `domain_op`.

### Projecting the current entity

`project/2` replays entries for a specific schema onto a base entity:

```elixir
current_room = Shigoto.ChangesetLog.project(log, loaded_room)
```

`project/1` projects all schemas and returns a `%{module => entity}` map:

```elixir
%{MyApp.Room => current_room, MyApp.Room.History => current_history} =
  Shigoto.ChangesetLog.project(log)
```

### Multi-schema logs

A single `ChangesetLog` can accumulate changesets for multiple schemas. The
executor expands each entry into an indexed `Ecto.Multi` operation:

```elixir
# log has 2 entries: MyApp.Room (insert) and MyApp.Room.History (insert)
# → Multi ops: {:log, 0} and {:log, 1}
persists [:log]
```

### When to use `ChangesetLog` vs plain maps

| Situation | Recommended |
|---|---|
| Single domain function returns related changesets | Plain map `%{room: cs, history: cs}` |
| Chaining multiple domain operations across a workflow step | `ChangesetLog` |
| Changesets use optimistic locking or prepare functions | `ChangesetLog` (directives preserved) |
| You need the current entity state between operations | `ChangesetLog` + `project/2` |

## Maps and lists of changesets

When a task produces multiple related changesets in a single function call,
returning a plain map is the simplest option:

```elixir
def reserve(%{available: true, suggested: room}, customer_id) do
  room_cs = MyApp.Room.changeset(room, %{status: :reserved, customer_id: customer_id})
  history_cs = MyApp.Room.History.changeset(%MyApp.Room.History{room_id: room.id}, %{status: :reserved})
  %{room: room_cs, history: history_cs}
end
```

The executor expands each map entry into a named `Ecto.Multi` operation.

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

Both plain maps and `ChangesetLog` preserve optimistic lock directives.
`ChangesetLog` stores the full `Ecto.Changeset` struct, so `prepare` functions
and `repo_opts` from `optimistic_lock` are automatically retained:

```elixir
room_cs =
  room
  |> MyApp.Room.changeset(%{status: :reserved})
  |> Ecto.Changeset.optimistic_lock(:version)

# Plain map:
%{room: room_cs}

# ChangesetLog (prepare function preserved, version not incremented until Repo.transaction):
Shigoto.ChangesetLog.append(room_cs)
```

Ecto will verify the lock version when `Repo.transaction(persist_multi)` runs.
If another process updated the record between the domain call and the commit,
the transaction fails with `Ecto.StaleEntryError`.

`ChangesetLog.project/2` does not apply prepare functions — the version
increment is a persistence concern and stays out of the projected entity state.

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
