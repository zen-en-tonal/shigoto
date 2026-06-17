defmodule MyApp.Workflows.RoomReserve do
  use Shigoto

  @doc "予約が完了したイベント"
  event :room_reserved do
    field :room_id, :uuid, required?: true
    field :reserved_by, :uuid, required?: true
  end

  @doc "予約が失敗し、代替を提案したイベント"
  event :alternative_suggested do
    field :room_id, :uuid, required?: true
    field :alternative, :string, required?: true
  end

  workflow do
    inputs [
      prompt: :string,
      customer_id: :uuid,
    ]

    @doc "予約客の希望を解析する"
    task :parse_order do
      call {MyApp.LLM, :order, [:prompt]}
      produces :order
    end

    @doc "予約客の希望が利用可能かチェックする"
    task :check_availability do
      call {MyApp.Rooms, :get_rooms, [:repo, :order]}
      produces :rooms
    end

    @doc "予約客の希望が利用可能か判定する"
    decision :room_available? do
      evaluated_by {MyApp.Rooms, :room_available?, [:rooms]}
      branches [
        available: :reserve,
        not_available: :suggest_alternative
      ]
    end

    @doc "予約客の希望を予約する"
    task :reserve do
      call {MyApp.Rooms, :reserve, [:rooms, :customer_id]}
      produces :reserved_room
    end

    @doc "予約客の希望の代替を提案する"
    task :suggest_alternative do
      call {MyApp.LLM, :suggest_alternative, [:prompt]}
      produces :alternative
    end

    emit :room_reserved do
      after_node :reserve
      map :room_id, from: [:reserved_room, :id]
      map :reserved_by, from: [:customer_id]
    end

    emit :alternative_suggested do
      after_node :suggest_alternative
      map :room_id, from: [:alternative, :id]
      map :alternative, from: [:alternative, :name]
    end

    persists [
      :reserved_room,
    ]
  end

  @doc "予約客が注文を作成する"
  automation :customer_made_order do
    on {MyApp.Workflows.OrderSubmission, :order_submitted}
    idempotency_key [:order_id]

    map :prompt, from: [:prompt]
    map :customer_id, from: [:customer_id]
  end
end

defmodule MyApp.LLM do
  def order(prompt) do
    # LLMによる予約客の希望の解析
    # ...
  end

  def suggest_alternative(prompt) do
    # LLMによる予約客の希望の代替の提案
    # ...
  end
end

defmodule MyApp.Rooms do
  @type room :: 
    MyApp.Room.t() 
    | Ecto.Changeset.t() 
    | Shigoto.Ecto.ChangesetMulti.t() 
    | map()

  @doc """
  予約客の希望を取得する

  ## Example

      iex> MyApp.Rooms.get_rooms(MyApp.Repo, %{non_smoking: true})
      %{
        available: true,
        count: 2,
        rooms: [
          %_{id: 1, name: "テストルーム1"},
          %_{id: 2, name: "テストルーム2"},
        ],
        suggested: %_{id: 2, name: "テストルーム2"},
      }
  """
  def get_rooms(repo \\ MyApp.Repo, order) do
    MyApp.Rooms.query(order)
    |> repo.all()
    |> case do
      [] -> %{
        available: false,
      }
      rooms -> %{
        available: true,
        count: length(rooms),
        rooms: rooms,
        suggested: MyApp.Rooms.suggestion(rooms),
      }
    end
  end

  def suggestion(rooms) do
    Enum.random(rooms)
  end

  @doc """
  予約客の希望が利用可能かチェックする

  ## Example

      iex> MyApp.Rooms.room_available?(%{available: true})
      :available

      iex> MyApp.Rooms.room_available?(%{status: :available})
      :available

      iex> MyApp.Rooms.room_available?(%{status: :reserved})
      :not_available
  """
  def room_available?(%Shigoto.Ecto.ChangesetMulti{} = multi) do
    Shigoto.Ecto.ChangesetMulti.fetch!(multi, :room)
    |> room_available?()
  end

  def room_available?(%Ecto.Changeset{} = changeset) do
    room_available?(Ecto.Changeset.apply_changes(changeset))
  end

  def room_available?(%{available: true}) do
    :available
  end

  def room_available?(%{status: :available}) do
    :available
  end

  def room_available?(_room) do
    :not_available
  end

  @doc """
  予約客の希望を予約する

  ## Example

      iex> MyApp.Rooms.reserve(%{id: 1, status: :available}, "customer_id") 
      ...> |> Ecto.Changeset.apply_changes()
      %_{
        customer_id: "customer_id",
        id: 1,
        status: :reserved,
        updated_at: ~N[2023-01-01 00:00:00]
      }
  """
  def reserve(%{available: true, suggested: room}, customer_id) do
    reserve(room, customer_id)
  end

  def reserve(%Shigoto.Ecto.ChangesetMulti{} = multi, customer_id) do
    Shigoto.Ecto.ChangesetMulti.flat_map(multi, :room, fn room ->
      reserve(room, customer_id)
    end)
  end

  def reserve(%Ecto.Changeset{} = changeset, customer_id) do
    reserve(Ecto.Changeset.apply_changes(changeset), customer_id)
  end

  def reserve(%{status: :available} = room, customer_id) do
    room_changset = 
      room
      |> MyApp.Room.changeset(%{
        customer_id: customer_id, 
        status: :reserved, 
      })
      |> Ecto.Changeset.optimistic_lock(:updated_at)
    
    history_changeset = 
      %MyApp.Room.History{room_id: room.id}
      |> MyApp.Room.History.changeset(%{status: :reserved})

    Shigoto.Ecto.ChangesetMulti.new(%{
      room: room_changset,
      history: history_changeset
    })
  end

  def reserve(%{status: :reserved, customer_id: customer_id} = room, customer_id) do
    room
  end

  def history(%{history: history}), do: history
  def history(%Ecto.Changeset{} = changeset), do: history(Ecto.Changeset.apply_changes(changeset))
  def history(_), do: []
end

defmodule MyApp.Room do
  use Ecto.Schema
  import Ecto.Changeset

  schema "rooms" do
    field :name, :string
    field :status, Ecto.Enum, values: [:available, :reserved]
    field :customer_id, :binary_id
    has_many :history, MyApp.Room.History

    timestamps()
  end

  def changeset(room, attrs) do
    room
    |> cast(attrs, [:name, :status, :customer_id, :updated_at])
    |> validate_required([:name, :status, :customer_id])
    |> validate_inclusion(:status, ~w[available reserved])
  end
end

defmodule MyApp.Room.History do
  use Ecto.Schema
  import Ecto.Changeset

  schema "room_history" do
    belongs_to :room, MyApp.Room
    field :status, Ecto.Enum, values: [:available, :reserved]
    timestamps()
  end

  def changeset(room, attrs) do
    room
    |> cast(attrs, [:status])
    |> validate_required([:status])
    |> validate_inclusion(:status, ~w[available reserved])
  end
end
