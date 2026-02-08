defmodule Hub.Schemas.MessageThread do
  @moduledoc """
  Schema for conversation threads — structured message grouping between agents.

  Threads scope conversations by type: dm, squad, task, or escalation.
  Messages within threads are stored in StorePort (Rust store).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "message_threads" do
    field :thread_id, :string        # "thr_xxxx" human-readable
    field :subject, :string
    field :scope, :string, default: "dm"  # "dm", "squad", "task", "escalation"
    field :status, :string, default: "open"  # "open", "closed", "archived"
    field :participant_ids, {:array, :string}, default: []  # agent_ids
    field :task_id, :string          # linked kanban task_id (optional)
    field :metadata, :map, default: %{}
    field :message_count, :integer, default: 0
    field :last_message_at, :utc_datetime
    field :closed_at, :utc_datetime
    field :closed_by, :string        # agent_id who closed it
    field :close_reason, :string

    belongs_to :fleet, Hub.Auth.Fleet
    belongs_to :squad, Hub.Groups.Group
    belongs_to :tenant, Hub.Auth.Tenant

    field :created_by, :string       # agent_id

    timestamps()
  end

  @cast_fields [
    :thread_id, :subject, :scope, :status, :participant_ids,
    :task_id, :metadata, :message_count, :last_message_at,
    :closed_at, :closed_by, :close_reason, :created_by,
    :fleet_id, :squad_id, :tenant_id
  ]

  def changeset(thread, attrs) do
    thread
    |> cast(attrs, @cast_fields)
    |> validate_required([:thread_id, :subject, :fleet_id, :tenant_id, :created_by])
    |> validate_inclusion(:scope, ["dm", "squad", "task", "escalation"])
    |> validate_inclusion(:status, ["open", "closed", "archived"])
    |> unique_constraint(:thread_id)
  end
end
