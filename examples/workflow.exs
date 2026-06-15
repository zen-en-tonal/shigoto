defmodule MyApp.Workflows.OrderApproval do
  use Shigoto

  @moduledoc """
  注文承認ドメインのワークフロー仕様。
  """

  event :order_approved do
    field :order_id, :uuid, required?: true
  end

  event :order_approval_requested do
    field :order_id, :uuid, required?: true
  end

  workflow :approve_order do
    input :order_id, :uuid
    input :ordered_at, :datetime

    assert :order_is_fresh do
      requires [:ordered_at]
      evaluated_by {MyApp.OrderPolicy, :fresh?, 1}
    end

    task :load_order do
      requires [:order_id]
      after_nodes [:order_is_fresh]
      call {MyApp.Orders, :get_order, 1}
      produces :order
    end

    decision :approval_required do
      summary "管理者承認が必要か判定する"
      requires [:order]
      evaluated_by {MyApp.OrderPolicy, :approval_required?, 1}
      branches [
        required: :request_manager_approval,
        not_required: :mark_approved
      ]
    end

    task :request_manager_approval do
      requires [:order]
      workflow {MyApp.Workflows.Approvals, :request_manager_approval}
      produces :approval_request
    end

    task :mark_approved do
      requires [:order]
      call {MyApp.Orders, :mark_approved, 1}
      produces :approved_order
    end

    emit :order_approved do
      after_nodes [:mark_approved]

      map :order_id, from: [:order, :id]
    end

    emit :order_approval_requested do
      after_nodes [:request_manager_approval]

      map :order_id, from: [:order, :id]
    end
  end

  automation :approve_order_when_submitted do
    on {MyApp.Workflows.OrderSubmission, :order_submitted}
    idempotency_key [:order_id]
    run :approve_order

    map :order_id, from: [:order_id]
    map :ordered_at, from: [:ordered_at]
  end

  automation :approve_order_when_submitted_again do
    on {MyApp.Workflows.OrderSubmission, :order_submitted}
    idempotency_key [:order_id]
    run :approve_order

    map :order_id, from: [:order_id]
    map :ordered_at, from: [:ordered_at]
  end
end

dot = 
Shigoto.Export.Mermaid.workflow(
  MyApp.Workflows.OrderApproval,
  :approve_order
)
File.write!("approve_order.mermaid", dot)
