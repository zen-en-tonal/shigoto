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

  workflow do
    inputs [
      order_id: :uuid,
      ordered_at: :datetime
    ]

    assert :order_is_fresh do
      evaluated_by {MyApp.OrderPolicy, :fresh?, [:ordered_at]}
    end

    task :load_order do
      after_node :order_is_fresh

      call {MyApp.Orders, :get_order, [:repo, :order_id]}

      produces :order
    end

    decision :approval_required do
      summary "管理者承認が必要か判定する"

      evaluated_by {MyApp.OrderPolicy, :approval_required?, [:order]}

      branches [
        required: :request_manager_approval,
        not_required: :mark_approved
      ]
    end

    task :request_manager_approval do
      workflow {MyApp.Workflows.Approvals, :request_manager_approval, [:order]}

      produces :approval_request
    end

    task :mark_approved do
      call {MyApp.Orders, :mark_approved, [:repo, :order]}

      produces :approved_order
    end

    emit :order_approved do
      after_node :mark_approved

      map :order_id, from: [:order, :id]
    end

    emit :order_approval_requested do
      after_node :request_manager_approval

      map :order_id, from: [:order, :id]
    end
  end

  automation :approve_order_when_submitted do
    on {MyApp.Workflows.OrderSubmission, :order_submitted}
    idempotency_key [:order_id]

    map :order_id, from: [:order_id]
    map :ordered_at, from: [:ordered_at]
  end

  automation :approve_order_when_submitted_again do
    on {MyApp.Workflows.OrderSubmission, :order_submitted_again}
    idempotency_key [:order_id]

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
