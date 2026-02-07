defmodule Hub.Groups.GroupMember do
  @moduledoc """
  Schema for group membership — tracks which agents belong to which groups.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_roles ~w(member admin owner)

  schema "group_members" do
    field :agent_id, :string
    field :role, :string, default: "member"
    field :joined_at, :utc_datetime

    belongs_to :group, Hub.Groups.Group

    timestamps()
  end

  def changeset(member, attrs) do
    member
    |> cast(attrs, [:group_id, :agent_id, :role, :joined_at])
    |> validate_required([:group_id, :agent_id, :joined_at])
    |> validate_inclusion(:role, @valid_roles)
    |> unique_constraint([:group_id, :agent_id])
  end
end
