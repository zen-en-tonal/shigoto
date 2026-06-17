# Helper domain function modules — defined at top level so workflow DSL macros
# can reference them with fully qualified names during compile-time verification.

defmodule Shigoto.ExecutorTest.Calc do
  def double(x), do: x * 2
  def add(a, b), do: a + b
  def repo_add(repo, a, b), do: {:ok, {repo, a + b}}
  def fail(_), do: {:error, :boom}
  def raise!(_), do: raise(ArgumentError, "intentional raise")
  def classify(n) when n > 0, do: :positive
  def classify(n) when n < 0, do: :negative
  def classify(0), do: :zero
  def is_positive(n), do: n > 0
end

defmodule Shigoto.ExecutorTest.FakeRecord do
  use Ecto.Schema

  schema "fake_records" do
    field(:name, :string)
  end
end

defmodule Shigoto.ExecutorTest.PersistTasks do
  alias Shigoto.ExecutorTest.FakeRecord

  def make_insert(_),
    do: Ecto.Changeset.change(%FakeRecord{}, name: "new")

  def make_update(_) do
    loaded = Ecto.put_meta(%FakeRecord{}, state: :loaded)
    Ecto.Changeset.change(loaded, name: "updated")
  end

  def make_changeset_multi(_),
    do: %{record: Ecto.Changeset.change(%FakeRecord{}, name: "bundled")}

  def make_nested_changeset_map(_),
    do: %{
      group: %{
        first: Ecto.Changeset.change(%FakeRecord{}, name: "nested1"),
        second: Ecto.Changeset.change(%FakeRecord{}, name: "nested2")
      },
      direct: Ecto.Changeset.change(%FakeRecord{}, name: "direct")
    }

  def make_changeset_list(_),
    do: [
      Ecto.Changeset.change(%FakeRecord{}, name: "item1"),
      Ecto.Changeset.change(%FakeRecord{}, name: "item2")
    ]
end

# ---- Workflow modules ----

defmodule Shigoto.ExecutorTest.SimpleWf do
  use Shigoto

  workflow :simple do
    input(:n, :integer)

    task :doubled do
      call({Shigoto.ExecutorTest.Calc, :double, [:n]})
      produces(:result)
    end
  end
end

defmodule Shigoto.ExecutorTest.TwoTaskWf do
  use Shigoto

  workflow :chain do
    input(:a, :integer)
    input(:b, :integer)

    task :summed do
      call({Shigoto.ExecutorTest.Calc, :add, [:a, :b]})
      produces(:total)
    end

    task :doubled do
      call({Shigoto.ExecutorTest.Calc, :double, [:total]})
      produces(:result)
    end
  end
end

defmodule Shigoto.ExecutorTest.DecisionWf do
  use Shigoto

  workflow :decide do
    input(:n, :integer)

    decision :sign do
      evaluated_by({Shigoto.ExecutorTest.Calc, :classify, [:n]})
      branches([positive: :on_pos, negative: :on_neg, zero: :on_zero])
    end

    task :on_pos do
      call({Shigoto.ExecutorTest.Calc, :double, [:n]})
      produces(:pos_result)
    end

    task :on_neg do
      call({Shigoto.ExecutorTest.Calc, :double, [:n]})
      produces(:neg_result)
    end

    task :on_zero do
      call({Shigoto.ExecutorTest.Calc, :double, [:n]})
      produces(:zero_result)
    end
  end
end

defmodule Shigoto.ExecutorTest.AssertWf do
  use Shigoto

  workflow :guarded do
    input(:n, :integer)

    assert :check_positive do
      evaluated_by({Shigoto.ExecutorTest.Calc, :is_positive, [:n]})
    end

    task :doubled do
      call({Shigoto.ExecutorTest.Calc, :double, [:n]})
      produces(:result)
      after_nodes([:check_positive])
    end
  end
end

defmodule Shigoto.ExecutorTest.FailWf do
  use Shigoto

  workflow :will_fail do
    input(:n, :integer)

    task :bad do
      call({Shigoto.ExecutorTest.Calc, :fail, [:n]})
      produces(:result)
    end
  end
end

defmodule Shigoto.ExecutorTest.RaiseWf do
  use Shigoto

  workflow :will_raise do
    input(:n, :integer)

    task :boom do
      call({Shigoto.ExecutorTest.Calc, :raise!, [:n]})
      produces(:result)
    end
  end
end

defmodule Shigoto.ExecutorTest.RepoWf do
  use Shigoto

  workflow :with_repo do
    input(:a, :integer)
    input(:b, :integer)

    task :summed do
      call({Shigoto.ExecutorTest.Calc, :repo_add, [:repo, :a, :b]})
      produces(:result)
    end
  end
end

defmodule Shigoto.ExecutorTest.InsertWf do
  use Shigoto

  workflow :inserting do
    input(:n, :integer)

    task :make_record do
      call({Shigoto.ExecutorTest.PersistTasks, :make_insert, [:n]})
      produces(:record)
    end

    persists([:record])
  end
end

defmodule Shigoto.ExecutorTest.UpdateWf do
  use Shigoto

  workflow :updating do
    input(:n, :integer)

    task :make_record do
      call({Shigoto.ExecutorTest.PersistTasks, :make_update, [:n]})
      produces(:record)
    end

    persists([:record])
  end
end

defmodule Shigoto.ExecutorTest.CmWf do
  use Shigoto

  workflow :multi_changeset do
    input(:n, :integer)

    task :make_changes do
      call({Shigoto.ExecutorTest.PersistTasks, :make_changeset_multi, [:n]})
      produces(:changes)
    end

    persists([:changes])
  end
end

defmodule Shigoto.ExecutorTest.NestedCmWf do
  use Shigoto

  workflow :nested_changeset_map do
    input(:n, :integer)

    task :make_changes do
      call({Shigoto.ExecutorTest.PersistTasks, :make_nested_changeset_map, [:n]})
      produces(:changes)
    end

    persists([:changes])
  end
end

defmodule Shigoto.ExecutorTest.ListCmWf do
  use Shigoto

  workflow :changeset_list do
    input(:n, :integer)

    task :make_changes do
      call({Shigoto.ExecutorTest.PersistTasks, :make_changeset_list, [:n]})
      produces(:changes)
    end

    persists([:changes])
  end
end

defmodule Shigoto.ExecutorTest.EmitWf do
  use Shigoto

  event(:thing_done) do
    field(:value, :integer)
  end

  workflow :emitting do
    input(:n, :integer)

    task :doubled do
      call({Shigoto.ExecutorTest.Calc, :double, [:n]})
      produces(:result)
    end

    emit :thing_done do
      after_nodes([:doubled])
      map(:value, from: [:result])
    end
  end
end

# Sub-workflow: inner has a persist, outer calls inner as a sub-workflow task.
defmodule Shigoto.ExecutorTest.SubInnerWf do
  use Shigoto

  workflow :sub_inner do
    input(:n, :integer)

    task :make_record do
      call({Shigoto.ExecutorTest.PersistTasks, :make_insert, [:n]})
      produces(:record)
    end

    persists([:record])
  end
end

defmodule Shigoto.ExecutorTest.SubOuterWf do
  use Shigoto

  workflow :sub_outer do
    input(:n, :integer)

    task :inner_run do
      workflow({Shigoto.ExecutorTest.SubInnerWf, :sub_inner})
      requires([:n])
      produces(:inner_ctx)
    end
  end
end

# Automation test module.
defmodule Shigoto.ExecutorTest.AutomationWf do
  use Shigoto

  event :order_placed do
    field(:amount, :integer)
    field(:item, :string)
  end

  workflow :process_order do
    input(:amount, :integer)
    input(:item, :string)

    task :doubled do
      call({Shigoto.ExecutorTest.Calc, :double, [:amount]})
      produces(:result)
    end
  end

  automation :on_order_placed do
    on(:order_placed)
    run(:process_order)

    map(:amount, from: [:amount])
    map(:item, from: [:item])
  end
end

# Anonymous workflow — tests that the :__default__ name is inferred at runtime.
defmodule Shigoto.ExecutorTest.AnonWf do
  use Shigoto

  workflow do
    input(:n, :integer)

    task :doubled do
      call({Shigoto.ExecutorTest.Calc, :double, [:n]})
      produces(:result)
    end
  end
end

# ---- Tests ----

defmodule Shigoto.ExecutorTest do
  use ExUnit.Case, async: true

  alias Shigoto.Executor

  defp multi_empty?(%Ecto.Multi{operations: ops}), do: ops == []

  test "basic task: result in context, persist multi empty" do
    assert {:ok, ctx, multi, _emits} =
             Executor.run(Shigoto.ExecutorTest.SimpleWf, :simple, %{n: 5})

    assert ctx.result == 10
    assert multi_empty?(multi)
  end

  test "chained tasks: dependency resolved via produces/requires" do
    assert {:ok, ctx, _multi, _emits} =
             Executor.run(Shigoto.ExecutorTest.TwoTaskWf, :chain, %{a: 3, b: 7})

    assert ctx.total == 10
    assert ctx.result == 20
  end

  test "decision: only taken branch vertex executes" do
    # positive branch
    assert {:ok, ctx_pos, _, _} =
             Executor.run(Shigoto.ExecutorTest.DecisionWf, :decide, %{n: 4})

    assert ctx_pos.sign == :positive
    assert ctx_pos.pos_result == 8
    refute Map.has_key?(ctx_pos, :neg_result)
    refute Map.has_key?(ctx_pos, :zero_result)

    # negative branch
    assert {:ok, ctx_neg, _, _} =
             Executor.run(Shigoto.ExecutorTest.DecisionWf, :decide, %{n: -2})

    assert ctx_neg.sign == :negative
    assert ctx_neg.neg_result == -4
    refute Map.has_key?(ctx_neg, :pos_result)
    refute Map.has_key?(ctx_neg, :zero_result)

    # zero branch
    assert {:ok, ctx_zero, _, _} =
             Executor.run(Shigoto.ExecutorTest.DecisionWf, :decide, %{n: 0})

    assert ctx_zero.sign == :zero
    assert ctx_zero.zero_result == 0
    refute Map.has_key?(ctx_zero, :pos_result)
    refute Map.has_key?(ctx_zero, :neg_result)
  end

  test "assertion passes: workflow completes" do
    assert {:ok, ctx, _multi, _emits} =
             Executor.run(Shigoto.ExecutorTest.AssertWf, :guarded, %{n: 7})

    assert ctx.result == 14
  end

  test "assertion fails: returns assertion_failed reason" do
    assert {:error, {:assertion_failed, :check_positive}, _ctx, _emits} =
             Executor.run(Shigoto.ExecutorTest.AssertWf, :guarded, %{n: -1})
  end

  test "task failure: returns task_failed with reason" do
    assert {:error, {:task_failed, :bad, :boom}, _ctx, _emits} =
             Executor.run(Shigoto.ExecutorTest.FailWf, :will_fail, %{n: 1})
  end

  test "task raise: returns task_raised with exception" do
    assert {:error, {:task_raised, :boom, %ArgumentError{}}, _ctx, _emits} =
             Executor.run(Shigoto.ExecutorTest.RaiseWf, :will_raise, %{n: 1})
  end

  test "repo option: passed to functions with :repo in arg spec" do
    assert {:ok, ctx, _multi, _emits} =
             Executor.run(
               Shigoto.ExecutorTest.RepoWf,
               :with_repo,
               %{a: 3, b: 4},
               repo: :test_repo
             )

    # repo_add returns {:ok, {repo, sum}} — executor normalizes to the inner value
    assert ctx.result == {:test_repo, 7}
  end

  test "persists: Ecto.Changeset with :built state → insert op in multi" do
    assert {:ok, ctx, multi, _emits} =
             Executor.run(Shigoto.ExecutorTest.InsertWf, :inserting, %{n: 1})

    assert %Ecto.Changeset{} = ctx.record
    refute multi_empty?(multi)
    [{op_name, {:changeset, cs, _}}] = Enum.reverse(multi.operations)
    assert op_name == :record
    assert cs.action == :insert
  end

  test "persists: Ecto.Changeset with :loaded state → update op in multi" do
    assert {:ok, ctx, multi, _emits} =
             Executor.run(Shigoto.ExecutorTest.UpdateWf, :updating, %{n: 1})

    assert %Ecto.Changeset{} = ctx.record
    refute multi_empty?(multi)
    [{op_name, {:changeset, cs, _}}] = Enum.reverse(multi.operations)
    assert op_name == :record
    assert cs.action == :update
  end

  test "persists: plain map of changesets → expanded into multi" do
    assert {:ok, ctx, multi, _emits} =
             Executor.run(Shigoto.ExecutorTest.CmWf, :multi_changeset, %{n: 1})

    assert %{record: %Ecto.Changeset{}} = ctx.changes
    refute multi_empty?(multi)
  end

  test "persists: nested changeset map → recursively expanded into multi" do
    assert {:ok, ctx, multi, _emits} =
             Executor.run(Shigoto.ExecutorTest.NestedCmWf, :nested_changeset_map, %{n: 1})

    assert %{group: %{first: %Ecto.Changeset{}, second: %Ecto.Changeset{}}, direct: %Ecto.Changeset{}} =
             ctx.changes

    refute multi_empty?(multi)
  end

  test "persists: list of changesets → expanded into multi with indexed op keys" do
    assert {:ok, ctx, multi, _emits} =
             Executor.run(Shigoto.ExecutorTest.ListCmWf, :changeset_list, %{n: 1})

    assert [%Ecto.Changeset{}, %Ecto.Changeset{}] = ctx.changes
    refute multi_empty?(multi)
  end

  test "no persists declared: multi stays empty" do
    assert {:ok, ctx, multi, _emits} =
             Executor.run(Shigoto.ExecutorTest.SimpleWf, :simple, %{n: 5})

    assert ctx.result == 10
    assert multi_empty?(multi)
  end

  test "emit: payload returned in emits list" do
    assert {:ok, ctx, _multi, emits} =
             Executor.run(Shigoto.ExecutorTest.EmitWf, :emitting, %{n: 6})

    assert ctx.result == 12
    assert [{event_ref, payload}] = emits
    assert event_ref == {Shigoto.ExecutorTest.EmitWf, :thing_done}
    assert payload == %{value: 12}
  end

  test "emit: emits list is empty when workflow has no emit nodes" do
    assert {:ok, _ctx, _multi, emits} =
             Executor.run(Shigoto.ExecutorTest.SimpleWf, :simple, %{n: 5})

    assert emits == []
  end

  test "sub-workflow: persists bubbled into parent multi" do
    assert {:ok, ctx, multi, _emits} =
             Executor.run(Shigoto.ExecutorTest.SubOuterWf, :sub_outer, %{n: 1})

    assert is_map(ctx.inner_ctx)
    assert %Ecto.Changeset{} = ctx.inner_ctx.record
    refute multi_empty?(multi)
  end

  test "run_automation: maps event payload to workflow inputs" do
    event_payload = %{amount: 5, item: "widget"}

    assert {:ok, ctx, _multi, _emits} =
             Executor.run_automation(
               Shigoto.ExecutorTest.AutomationWf,
               :on_order_placed,
               event_payload
             )

    assert ctx.amount == 5
    assert ctx.item == "widget"
    assert ctx.result == 10
  end

  test "missing required input: raises ArgumentError" do
    assert_raise ArgumentError, ~r/missing required input/, fn ->
      Executor.run(Shigoto.ExecutorTest.SimpleWf, :simple, %{})
    end
  end

  test "partial context returned on task failure" do
    assert {:error, {:task_failed, :bad, :boom}, partial_ctx, _emits} =
             Executor.run(Shigoto.ExecutorTest.FailWf, :will_fail, %{n: 42})

    assert partial_ctx.n == 42
    refute Map.has_key?(partial_ctx, :result)
  end

  test "anonymous workflow: name inferred from module last component" do
    # Module Shigoto.ExecutorTest.AnonWf → last component AnonWf → :anon_wf
    [wf] = Shigoto.Info.workflows(Shigoto.ExecutorTest.AnonWf)
    assert wf.name == :anon_wf

    assert {:ok, ctx, _multi, _emits} =
             Executor.run(Shigoto.ExecutorTest.AnonWf, :anon_wf, %{n: 3})

    assert ctx.result == 6
  end
end
