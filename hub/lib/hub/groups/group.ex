defmodule Hub.Groups.Group do
  @moduledoc """
  Schema for groups — squads, pods, and channels within a fleet.

  - **squad**: Persistent team with fixed membership (e.g., DevOps squad)
  - **pod**: Ephemeral group for a specific task, dissolves when done
  - **channel**: Topic-based group anyone can join/leave
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_types ~w(squad pod channel)
  @valid_statuses ~w(active dissolved)

  schema "groups" do
    field :group_id, :string
    field :name, :string
    field :type, :string, default: "squad"
    field :created_by, :string
    field :capabilities, {:array, :string}, default: []
    field :settings, :map, default: %{}
    field :status, :string, default: "active"
    field :dissolved_at, :utc_datetime
    field :result, :string

    belongs_to :fleet, Hub.Auth.Fleet
    has_many :members, Hub.Groups.GroupMember

    timestamps()
  end

  def changeset(group, attrs) do
    group
    |> cast(attrs, [:group_id, :name, :type, :fleet_id, :created_by, :capabilities, :settings, :status, :dissolved_at, :result])
    |> validate_required([:group_id, :name, :type, :fleet_id])
    |> validate_inclusion(:type, @valid_types)
    |> validate_inclusion(:status, @valid_statuses)
    |> unique_constraint(:group_id)
    |> unique_constraint([:name, :fleet_id])
  end
end
