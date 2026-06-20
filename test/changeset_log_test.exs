defmodule Shigoto.ChangesetLogTest.FakeRecord do
  use Ecto.Schema

  schema "fake_records" do
    field(:name, :string)
    field(:status, :string)
    field(:version, :integer)
  end
end

defmodule Shigoto.ChangesetLogTest.OtherRecord do
  use Ecto.Schema

  schema "other_records" do
    field(:value, :string)
  end
end

defmodule Shigoto.ChangesetLogTest.LogWf do
  use Shigoto

  workflow :run_log do
    input(:n, :integer)

    task :make_log do
      call({Shigoto.ChangesetLogTest.Domain, :two_step, [:n]})
      produces(:log)
    end

    persists([:log])
  end
end

defmodule Shigoto.ChangesetLogTest.Domain do
  alias Shigoto.ChangesetLogTest.FakeRecord

  def two_step(n) do
    base = struct(FakeRecord)

    cs1 = Ecto.Changeset.change(base, name: "step#{n}")
    log = Shigoto.ChangesetLog.append(cs1, domain_op: :name)

    current = Shigoto.ChangesetLog.project(log, base)
    cs2 = Ecto.Changeset.change(current, status: "done#{n}")
    Shigoto.ChangesetLog.append(log, cs2, domain_op: :status)
  end

  def update_step(entity) do
    loaded = Ecto.put_meta(entity, state: :loaded)
    cs = Ecto.Changeset.change(loaded, name: "updated")
    Shigoto.ChangesetLog.append(cs, domain_op: :update)
  end
end

defmodule Shigoto.ChangesetLogTest do
  use ExUnit.Case, async: true

  alias Shigoto.ChangesetLog
  alias Shigoto.ChangesetLogTest.FakeRecord
  alias Shigoto.ChangesetLogTest.OtherRecord

  defp build_cs(attrs), do: Ecto.Changeset.change(struct(FakeRecord), attrs)

  defp loaded_cs(attrs) do
    loaded = Ecto.put_meta(struct(FakeRecord), state: :loaded)
    Ecto.Changeset.change(loaded, attrs)
  end

  # ---- append/1 (create form) ----

  describe "append/1 create form" do
    test "creates log with one entry" do
      log = ChangesetLog.append(build_cs(name: "new"))
      assert length(log.entries) == 1
    end

    test "entry stores the changeset directly" do
      cs = build_cs(name: "x")
      log = ChangesetLog.append(cs)
      assert [%{changeset: ^cs}] = log.entries
    end

    test "entry schema is cs.data.__struct__" do
      log = ChangesetLog.append(build_cs(name: "x"))
      [entry] = log.entries
      assert entry.changeset.data.__struct__ == FakeRecord
    end

    test "registers cs.data as initial for schema" do
      cs = build_cs(name: "new")
      log = ChangesetLog.append(cs)
      assert log.initial[FakeRecord] == cs.data
    end

    test "insert changeset has meta state :built" do
      log = ChangesetLog.append(build_cs(name: "new"))
      [entry] = log.entries
      assert entry.changeset.data.__meta__.state == :built
    end

    test "update changeset has meta state :loaded" do
      log = ChangesetLog.append(loaded_cs(name: "upd"))
      [entry] = log.entries
      assert entry.changeset.data.__meta__.state == :loaded
    end

    test "changeset changes are preserved" do
      log = ChangesetLog.append(build_cs(name: "x", status: "y"))
      [entry] = log.entries
      assert entry.changeset.changes == %{name: "x", status: "y"}
    end
  end

  # ---- append/2-3 (append-to-existing form) ----

  describe "append/2 append-to-existing" do
    test "appends entry to existing log" do
      log =
        build_cs(name: "first")
        |> ChangesetLog.append()
        |> ChangesetLog.append(build_cs(status: "second"))

      assert length(log.entries) == 2
    end

    test "does not overwrite initial for existing schema" do
      original = struct(FakeRecord, name: "original")
      cs1 = Ecto.Changeset.change(original, name: "first")
      log = ChangesetLog.append(cs1)

      cs2 = Ecto.Changeset.change(struct(FakeRecord, name: "second"), name: "second")
      log = ChangesetLog.append(log, cs2)

      assert log.initial[FakeRecord] == original
    end

    test "auto-registers initial for new schema on append" do
      log = ChangesetLog.append(build_cs(name: "x"))

      other_base = struct(OtherRecord, value: "v")
      other_cs = Ecto.Changeset.change(other_base, value: "changed")
      log = ChangesetLog.append(log, other_cs)

      assert log.initial[OtherRecord] == other_base
    end
  end

  describe "append/3 opts" do
    test "domain_op stored" do
      log = ChangesetLog.append(build_cs(name: "a"), domain_op: :reserve)
      assert [%{domain_op: :reserve}] = log.entries
    end

    test "applied_at stored when provided" do
      dt = ~U[2026-01-01 00:00:00Z]
      log = ChangesetLog.append(build_cs(name: "a"), applied_at: dt)
      assert [%{applied_at: ^dt}] = log.entries
    end

    test "metadata stored" do
      log = ChangesetLog.append(build_cs(name: "a"), metadata: %{src: :test})
      assert [%{metadata: %{src: :test}}] = log.entries
    end

    test "missing opts default to nil/%{}" do
      log = ChangesetLog.append(build_cs(name: "a"))
      assert [%{domain_op: nil, metadata: %{}}] = log.entries
    end
  end

  describe "entries order" do
    test "entries accumulate in append order" do
      log =
        build_cs(name: "first")
        |> ChangesetLog.append(domain_op: :one)
        |> ChangesetLog.append(build_cs(status: "second"), domain_op: :two)

      assert [%{domain_op: :one}, %{domain_op: :two}] = log.entries
    end
  end

  # ---- project/2 ----

  describe "project/2" do
    test "empty log returns base unchanged" do
      base = struct(FakeRecord, name: "seed")
      assert ChangesetLog.project(%ChangesetLog{}, base) == base
    end

    test "single entry applied over explicit base" do
      base = struct(FakeRecord, name: "original", status: "old")
      log = ChangesetLog.append(build_cs(name: "changed"))
      projected = ChangesetLog.project(log, base)
      assert projected.name == "changed"
      assert projected.status == "old"
    end

    test "two entries applied in order over base" do
      base = struct(FakeRecord)

      log =
        build_cs(name: "step1")
        |> ChangesetLog.append()
        |> ChangesetLog.append(build_cs(status: "step2"))

      projected = ChangesetLog.project(log, base)
      assert projected.name == "step1"
      assert projected.status == "step2"
    end

    test "same log projected onto different bases" do
      log = ChangesetLog.append(build_cs(status: "done"))
      base_a = struct(FakeRecord, name: "a")
      base_b = struct(FakeRecord, name: "b")

      assert ChangesetLog.project(log, base_a).name == "a"
      assert ChangesetLog.project(log, base_b).name == "b"
    end

    test "ignores entries for other schemas" do
      base = struct(FakeRecord, name: "room")
      other_cs = Ecto.Changeset.change(struct(OtherRecord), value: "x")

      log =
        build_cs(name: "updated")
        |> ChangesetLog.append()
        |> ChangesetLog.append(other_cs)

      projected = ChangesetLog.project(log, base)
      assert projected.name == "updated"
      refute Map.has_key?(projected, :value)
    end
  end

  # ---- project/1 ----

  describe "project/1" do
    test "empty log returns empty map" do
      assert ChangesetLog.project(%ChangesetLog{}) == %{}
    end

    test "returns map keyed by schema module" do
      log = ChangesetLog.append(build_cs(name: "hello"))
      result = ChangesetLog.project(log)
      assert is_map(result)
      assert Map.has_key?(result, FakeRecord)
    end

    test "projected value reflects all entries for that schema" do
      log =
        build_cs(name: "step1")
        |> ChangesetLog.append()
        |> ChangesetLog.append(build_cs(status: "step2"))

      assert %{FakeRecord => %FakeRecord{name: "step1", status: "step2"}} = ChangesetLog.project(log)
    end

    test "multi-schema log returns entry for each schema" do
      other_cs = Ecto.Changeset.change(struct(OtherRecord), value: "v")

      log =
        build_cs(name: "room")
        |> ChangesetLog.append()
        |> ChangesetLog.append(other_cs)

      result = ChangesetLog.project(log)
      assert Map.has_key?(result, FakeRecord)
      assert Map.has_key?(result, OtherRecord)
      assert result[FakeRecord].name == "room"
      assert result[OtherRecord].value == "v"
    end
  end

  # ---- to_changesets/1 ----

  describe "to_changesets/1" do
    test "empty log returns []" do
      assert [] = ChangesetLog.to_changesets(%ChangesetLog{})
    end

    test "returns the stored changeset unchanged" do
      cs = build_cs(name: "new")
      log = ChangesetLog.append(cs)
      assert [^cs] = ChangesetLog.to_changesets(log)
    end

    test "insert entry has meta state :built" do
      log = ChangesetLog.append(build_cs(name: "new"))
      [cs] = ChangesetLog.to_changesets(log)
      assert cs.data.__meta__.state == :built
    end

    test "update entry has meta state :loaded" do
      log = ChangesetLog.append(loaded_cs(name: "upd"))
      [cs] = ChangesetLog.to_changesets(log)
      assert cs.data.__meta__.state == :loaded
    end

    test "multiple entries returned in order" do
      cs1 = build_cs(name: "a")
      cs2 = loaded_cs(status: "b")

      log =
        cs1
        |> ChangesetLog.append(domain_op: :one)
        |> ChangesetLog.append(cs2, domain_op: :two)

      assert [^cs1, ^cs2] = ChangesetLog.to_changesets(log)
    end

    test "multi-schema: each entry has correct schema" do
      other_cs = Ecto.Changeset.change(struct(OtherRecord), value: "v")

      log =
        build_cs(name: "room")
        |> ChangesetLog.append()
        |> ChangesetLog.append(other_cs)

      [cs1, cs2] = ChangesetLog.to_changesets(log)
      assert cs1.data.__struct__ == FakeRecord
      assert cs2.data.__struct__ == OtherRecord
    end

    test "update carries original entity identity" do
      original = Ecto.put_meta(struct(FakeRecord, name: "orig"), state: :loaded)
      cs = Ecto.Changeset.change(original, name: "updated")
      log = ChangesetLog.append(cs)

      [stored] = ChangesetLog.to_changesets(log)
      assert stored.data.name == "orig"
      assert stored.data.__meta__.state == :loaded
    end
  end

  # ---- apply/3 ----

  describe "apply/3" do
    test "single Changeset result appended to log" do
      base = struct(FakeRecord, name: "seed")
      log = ChangesetLog.append(build_cs(name: "seed"))

      log = ChangesetLog.apply(log, base, fn _entity ->
        build_cs(name: "applied")
      end)

      assert length(log.entries) == 2
      assert ChangesetLog.project(log, base).name == "applied"
    end

    test "list of Changesets all folded in order" do
      base = struct(FakeRecord)
      log = ChangesetLog.append(build_cs(name: "init"))

      log = ChangesetLog.apply(log, base, fn _entity ->
        [build_cs(name: "first"), build_cs(status: "second")]
      end)

      assert length(log.entries) == 3
      projected = ChangesetLog.project(log, base)
      assert projected.name == "first"
      assert projected.status == "second"
    end

    test "keyword list result stores domain_op from key" do
      base = struct(FakeRecord)
      log = ChangesetLog.append(build_cs(name: "init"))

      log = ChangesetLog.apply(log, base, fn _entity ->
        [reserve: build_cs(name: "room"), logging: build_cs(status: "history")]
      end)

      [_, %{domain_op: :reserve}, %{domain_op: :logging}] = log.entries
    end

    test "fun receives the current projected entity" do
      base = struct(FakeRecord, name: "original")
      log = ChangesetLog.append(build_cs(name: "mutated"))

      ChangesetLog.apply(log, base, fn entity ->
        send(self(), {:received, entity.name})
        build_cs(status: "done")
      end)

      assert_received {:received, "mutated"}
    end

    test "chained apply calls accumulate entries" do
      base = struct(FakeRecord)
      log = ChangesetLog.append(build_cs(name: "init"))

      log =
        log
        |> ChangesetLog.apply(base, fn _ -> build_cs(name: "first") end)
        |> ChangesetLog.apply(base, fn _ -> build_cs(status: "second") end)

      assert length(log.entries) == 3
    end
  end

  # ---- DB directives ----

  describe "DB directives" do
    defp locked_cs(attrs) do
      Ecto.put_meta(struct(FakeRecord, version: 1), state: :loaded)
      |> Ecto.Changeset.change(attrs)
      |> Ecto.Changeset.optimistic_lock(:version)
    end

    test "optimistic_lock prepare is preserved through append + to_changesets" do
      cs = locked_cs(name: "updated")
      log = ChangesetLog.append(cs)
      [stored] = ChangesetLog.to_changesets(log)

      assert stored.prepare == cs.prepare
    end

    test "repo_opts are preserved" do
      cs = locked_cs(name: "updated")
      log = ChangesetLog.append(cs)
      [stored] = ChangesetLog.to_changesets(log)

      assert stored.repo_opts == cs.repo_opts
    end

    test "all changeset fields are identical — to_changesets returns stored changeset" do
      cs = locked_cs(name: "updated")
      log = ChangesetLog.append(cs)
      assert [^cs] = ChangesetLog.to_changesets(log)
    end

    test "changeset without directives has empty prepare" do
      log = ChangesetLog.append(build_cs(name: "x"))
      [cs] = ChangesetLog.to_changesets(log)
      assert cs.prepare == []
      assert cs.repo_opts == []
    end

    test "directives are per-entry — second entry without lock has empty prepare" do
      log =
        locked_cs(name: "step1")
        |> ChangesetLog.append()
        |> ChangesetLog.append(loaded_cs(status: "step2"))

      [r1, r2] = ChangesetLog.to_changesets(log)
      assert length(r1.prepare) == 1
      assert r2.prepare == []
    end

    test "project does not apply prepare functions — version not incremented" do
      base = struct(FakeRecord, version: 1, name: "a")
      cs = Ecto.put_meta(base, state: :loaded)
           |> Ecto.Changeset.change(name: "b")
           |> Ecto.Changeset.optimistic_lock(:version)

      log = ChangesetLog.append(cs)
      projected = ChangesetLog.project(log, base)

      assert projected.name == "b"
      assert projected.version == 1
    end
  end

  # ---- executor integration ----

  describe "executor persists integration" do
    test "ChangesetLog in persists expands to indexed Multi ops" do
      {:ok, ctx, multi, _emits} =
        Shigoto.Executor.run(Shigoto.ChangesetLogTest.LogWf, :run_log, %{n: 3})

      assert %Shigoto.ChangesetLog{} = ctx.log
      assert ctx.log.entries |> length() == 2

      ops = Ecto.Multi.to_list(multi)
      assert length(ops) == 2
      assert Enum.any?(ops, fn {key, _} -> key == {:log, 0} end)
      assert Enum.any?(ops, fn {key, _} -> key == {:log, 1} end)
    end

    test "update log produces Multi.update ops" do
      loaded = Ecto.put_meta(struct(FakeRecord), state: :loaded)
      log = Shigoto.ChangesetLogTest.Domain.update_step(loaded)

      [cs] = ChangesetLog.to_changesets(log)
      assert cs.data.__meta__.state == :loaded
    end
  end
end
