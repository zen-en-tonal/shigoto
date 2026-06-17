# Helper domain modules — defined at top level so DSL macros can reference them.

defmodule Shigoto.AutomationTest.Calc do
  def double(x), do: x * 2
  def identity(x), do: x
  def fail(_), do: {:error, :boom}
  def repo_double(repo, x), do: {:ok, {repo, x * 2}}
end

# ---- Shigoto workflow modules ----

defmodule Shigoto.AutomationTest.Wf1 do
  use Shigoto

  event :local_event do
    field(:x, :integer)
  end

  event :shipped do
    field(:order_id, :string)
  end

  workflow :run_wf1 do
    input(:x, :integer)

    task :doubled do
      call({Shigoto.AutomationTest.Calc, :double, [:x]})
      produces(:result)
    end
  end

  automation :on_local do
    on(:local_event)
    run(:run_wf1)
    map(:x, from: [:x])
  end
end

defmodule Shigoto.AutomationTest.Wf2 do
  use Shigoto

  event :local_event do
    field(:x, :integer)
  end

  workflow :run_wf2 do
    input(:x, :integer)

    task :doubled do
      call({Shigoto.AutomationTest.Calc, :double, [:x]})
      produces(:result)
    end
  end

  automation :on_local do
    on(:local_event)
    run(:run_wf2)
    map(:x, from: [:x])
  end
end

# Listens to a tuple-form event ref from another module; has idempotency_key.
defmodule Shigoto.AutomationTest.Wf3 do
  use Shigoto

  workflow :run_wf3 do
    input(:order_id, :string)

    task :result do
      call({Shigoto.AutomationTest.Calc, :identity, [:order_id]})
      produces(:out)
    end
  end

  automation :on_shipped do
    on({Shigoto.AutomationTest.Wf1, :shipped})
    run(:run_wf3)
    idempotency_key([:order_id])
    map(:order_id, from: [:order_id])
  end
end

# Two automations on the same event — one succeeds, one fails — for error isolation tests.
defmodule Shigoto.AutomationTest.MixedWf do
  use Shigoto

  event :mixed_event do
    field(:x, :integer)
  end

  workflow :run_succeed do
    input(:x, :integer)

    task :doubled do
      call({Shigoto.AutomationTest.Calc, :double, [:x]})
      produces(:result)
    end
  end

  workflow :run_fail do
    input(:x, :integer)

    task :bad do
      call({Shigoto.AutomationTest.Calc, :fail, [:x]})
      produces(:result)
    end
  end

  automation :on_succeed do
    on(:mixed_event)
    run(:run_succeed)
    map(:x, from: [:x])
  end

  automation :on_fail do
    on(:mixed_event)
    run(:run_fail)
    map(:x, from: [:x])
  end
end

# For repo-forwarding test.
defmodule Shigoto.AutomationTest.RepoWf do
  use Shigoto

  event :repo_event do
    field(:x, :integer)
  end

  workflow :run_repo do
    input(:x, :integer)

    task :doubled do
      call({Shigoto.AutomationTest.Calc, :repo_double, [:repo, :x]})
      produces(:result)
    end
  end

  automation :on_repo_event do
    on(:repo_event)
    run(:run_repo)
    map(:x, from: [:x])
  end
end

# For multi-field idempotency_key test.
defmodule Shigoto.AutomationTest.MultiKeyWf do
  use Shigoto

  event :multi_key_event do
    field(:order_id, :string)
    field(:customer_id, :string)
  end

  workflow :run_multi_key do
    input(:order_id, :string)
    input(:customer_id, :string)

    task :result do
      call({Shigoto.AutomationTest.Calc, :identity, [:order_id]})
      produces(:out)
    end
  end

  automation :on_multi_key do
    on(:multi_key_event)
    run(:run_multi_key)
    idempotency_key([:order_id, :customer_id])
    map(:order_id, from: [:order_id])
    map(:customer_id, from: [:customer_id])
  end
end

# ---- Tests ----

defmodule Shigoto.AutomationTest do
  use ExUnit.Case, async: true

  alias Shigoto.Automation
  alias Shigoto.AutomationTest.{Wf1, Wf2, Wf3, MixedWf, RepoWf, MultiKeyWf}

  # ---- index/1 ----

  describe "index/1" do
    test "single module maps event to its automation" do
      idx = Automation.index([Wf1])

      assert idx[:local_event] == [{Wf1, :on_local}]
    end

    test "two modules with the same event ref appear under one key in registration order" do
      idx = Automation.index([Wf1, Wf2])

      assert idx[:local_event] == [{Wf1, :on_local}, {Wf2, :on_local}]
    end

    test "tuple event_ref is a valid key" do
      idx = Automation.index([Wf3])

      assert idx[{Wf1, :shipped}] == [{Wf3, :on_shipped}]
    end

    test "multiple modules with distinct events each appear under their own key" do
      idx = Automation.index([Wf1, Wf3])

      assert idx[:local_event] == [{Wf1, :on_local}]
      assert idx[{Wf1, :shipped}] == [{Wf3, :on_shipped}]
    end
  end

  # ---- match/2 ----

  describe "match/2" do
    test "emit tuple with atom event_ref matches the automation" do
      idx = Automation.index([Wf1])

      assert [{Wf1, :on_local}] = Automation.match(idx, {:local_event, %{x: 1}})
    end

    test "bare atom event_ref matches the same as emit tuple" do
      idx = Automation.index([Wf1])

      assert Automation.match(idx, :local_event) == Automation.match(idx, {:local_event, %{x: 1}})
    end

    test "module list builds index on the fly" do
      precomputed = Automation.index([Wf1])

      assert Automation.match([Wf1], {:local_event, %{x: 1}}) ==
               Automation.match(precomputed, {:local_event, %{x: 1}})
    end

    test "unregistered event returns empty list" do
      idx = Automation.index([Wf1])

      assert Automation.match(idx, :unknown_event) == []
    end

    test "emit tuple with tuple event_ref matches correctly" do
      idx = Automation.index([Wf3])
      emit = {{Wf1, :shipped}, %{order_id: "abc"}}

      assert [{Wf3, :on_shipped}] = Automation.match(idx, emit)
    end

    test "atom and tuple event refs do not cross-contaminate" do
      idx = Automation.index([Wf1, Wf3])

      assert [{Wf1, :on_local}] = Automation.match(idx, :local_event)
      assert [{Wf3, :on_shipped}] = Automation.match(idx, {Wf1, :shipped})
    end

    test "two modules with same event both returned in order" do
      idx = Automation.index([Wf1, Wf2])

      assert [{Wf1, :on_local}, {Wf2, :on_local}] =
               Automation.match(idx, {:local_event, %{x: 7}})
    end
  end

  # ---- idempotency_key/2 ----

  describe "idempotency_key/2" do
    test "single declared field returns automation_name:value" do
      auto_ref = {Wf3, :on_shipped}
      emit = {{Wf1, :shipped}, %{order_id: "order-123"}}

      assert "on_shipped:order-123" = Automation.idempotency_key(auto_ref, emit)
    end

    test "multi-field returns automation_name:v1:v2 in declaration order" do
      auto_ref = {MultiKeyWf, :on_multi_key}
      emit = {:multi_key_event, %{order_id: "ord-1", customer_id: "cust-9"}}

      assert "on_multi_key:ord-1:cust-9" = Automation.idempotency_key(auto_ref, emit)
    end

    test "automation with no idempotency_key returns nil" do
      auto_ref = {Wf1, :on_local}
      emit = {:local_event, %{x: 5}}

      assert nil == Automation.idempotency_key(auto_ref, emit)
    end

    test "string keys in payload are matched as atom fallback" do
      auto_ref = {Wf3, :on_shipped}
      emit = {{Wf1, :shipped}, %{"order_id" => "str-key-value"}}

      assert "on_shipped:str-key-value" = Automation.idempotency_key(auto_ref, emit)
    end

    test "keyword payload is supported" do
      auto_ref = {Wf3, :on_shipped}
      emit = {{Wf1, :shipped}, [order_id: "kw-value"]}

      assert "on_shipped:kw-value" = Automation.idempotency_key(auto_ref, emit)
    end
  end

  # ---- dispatch/2-3 ----

  describe "dispatch/2" do
    test "happy path: returns [{automation_name, {:ok, ctx, multi, emits}}]" do
      idx = Automation.index([Wf1])
      emit = {:local_event, %{x: 3}}

      assert [{:on_local, {:ok, ctx, _multi, _emits}}] = Automation.dispatch(idx, emit)
      assert ctx.result == 6
    end

    test "no matching automation returns empty list" do
      idx = Automation.index([Wf1])
      emit = {:nonexistent_event, %{x: 1}}

      assert [] = Automation.dispatch(idx, emit)
    end

    test "module list form produces same result as precomputed index" do
      idx = Automation.index([Wf1])
      emit = {:local_event, %{x: 4}}

      assert Automation.dispatch([Wf1], emit) == Automation.dispatch(idx, emit)
    end

    test "multiple automations on same event all run in order" do
      idx = Automation.index([Wf1, Wf2])
      emit = {:local_event, %{x: 5}}

      results = Automation.dispatch(idx, emit)
      assert length(results) == 2
      assert [{:on_local, {:ok, ctx1, _, _}}, {:on_local, {:ok, ctx2, _, _}}] = results
      assert ctx1.result == 10
      assert ctx2.result == 10
    end

    test "failing automation returns {:error, ...} without crashing" do
      idx = Automation.index([MixedWf])
      emit = {:mixed_event, %{x: 2}}

      results = Automation.dispatch(idx, emit)
      assert length(results) == 2
      assert Enum.any?(results, fn {_name, r} -> match?({:ok, _, _, _}, r) end)
      assert Enum.any?(results, fn {_name, r} -> match?({:error, _, _, _}, r) end)
    end

    test "tuple event_ref dispatches to the correct automation" do
      idx = Automation.index([Wf3])
      emit = {{Wf1, :shipped}, %{order_id: "ship-42"}}

      assert [{:on_shipped, {:ok, ctx, _multi, _emits}}] = Automation.dispatch(idx, emit)
      assert ctx.out == "ship-42"
    end
  end

  describe "dispatch/3" do
    test "opts are forwarded to executor (repo:)" do
      idx = Automation.index([RepoWf])
      emit = {:repo_event, %{x: 7}}
      fake_repo = :my_test_repo

      assert [{:on_repo_event, {:ok, ctx, _multi, _emits}}] =
               Automation.dispatch(idx, emit, repo: fake_repo)

      assert ctx.result == {:my_test_repo, 14}
    end
  end

  # ---- dispatch_all/2-3 ----

  describe "dispatch_all/2" do
    test "flat results across multiple emits in emit order" do
      idx = Automation.index([Wf1, Wf3])

      emits = [
        {:local_event, %{x: 2}},
        {{Wf1, :shipped}, %{order_id: "batch-order"}}
      ]

      results = Automation.dispatch_all(idx, emits)
      assert length(results) == 2
      assert [{:on_local, {:ok, ctx_local, _, _}}, {:on_shipped, {:ok, ctx_shipped, _, _}}] =
               results

      assert ctx_local.result == 4
      assert ctx_shipped.out == "batch-order"
    end

    test "empty emit list returns empty list" do
      idx = Automation.index([Wf1])

      assert [] = Automation.dispatch_all(idx, [])
    end

    test "multiple automations per emit are all included in the flat result" do
      idx = Automation.index([Wf1, Wf2])
      emits = [{:local_event, %{x: 3}}, {:local_event, %{x: 9}}]

      results = Automation.dispatch_all(idx, emits)
      assert length(results) == 4
    end
  end

  describe "dispatch_all/3" do
    test "opts forwarded for every emit in the list" do
      idx = Automation.index([RepoWf])
      emits = [{:repo_event, %{x: 1}}, {:repo_event, %{x: 2}}]

      results = Automation.dispatch_all(idx, emits, repo: :fake)
      assert length(results) == 2
      assert Enum.all?(results, fn {_, r} -> match?({:ok, _, _, _}, r) end)
    end
  end
end
