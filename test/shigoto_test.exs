defmodule ShigotoTest do
  use ExUnit.Case, async: true

  defmodule ExampleWorkflow do
    use Shigoto

    event :order_submitted do
      field :order_id, :uuid, required?: true
      field :submitted_by, :user_id, required?: true
    end

    workflow :approve_order do
      input :order_id, :uuid

      task :load_order,
        call: {MyApp.Orders, :get_order, 1},
        requires: [:order_id],
        produces: :order

      task :evaluate_policy,
        call: {MyApp.OrderPolicy, :evaluate, 1},
        requires: [:order],
        produces: :policy_result,
        after_nodes: [:load_order]

      decision :approval_required,
        evaluated_by: {MyApp.OrderPolicy, :approval_required?, 1},
        requires: [:policy_result],
        branches: [
          required: :request_manager_approval,
          not_required: :mark_approved
        ]

      task :request_manager_approval,
        call: {MyApp.Approvals, :request, 1},
        requires: [:order],
        produces: :approval_request

      task :mark_approved,
        call: {MyApp.Orders, :mark_approved, 1},
        requires: [:order],
        produces: :approved_order
    end

    automation :approve_order_when_submitted do
      on :order_submitted
      run :approve_order
      map :order_id, from: [:order_id]
    end
  end

  test "builds workflow IR from wrapper macros" do
    ir = Shigoto.IR.build(ExampleWorkflow)

    assert [%{name: :order_submitted, fields: [first_field, second_field]}] = ir.events
    assert first_field.name == :order_id
    assert second_field.name == :submitted_by

    assert [
             %{
               name: :approve_order,
               inputs: [input],
               tasks: [load_order, evaluate_policy, _request, _mark],
               decisions: [decision]
             }
           ] = ir.workflows

    assert input.name == :order_id
    assert load_order.name == :load_order
    assert evaluate_policy.after_nodes == [:load_order]
    assert decision.name == :approval_required

    assert [
             %{
               name: :approve_order_when_submitted,
               on: :order_submitted,
               run: :approve_order,
               mappings: [mapping]
             }
           ] = ir.automations

    assert mapping.target == :order_id
    assert mapping.from == [:order_id]
  end
end
