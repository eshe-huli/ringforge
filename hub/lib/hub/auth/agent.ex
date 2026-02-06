defmodule Hub.Auth.Agent do
  @moduledoc """
  Schema for agents — individual AI agents registered to a tenant/fleet.

  Each agent has a unique `agent_id` (e.g. "ag_abc123"), an optional
  Ed25519 public key for challenge-response auth, and metadata about
  its framework and capabilities.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agents" do
    field :agent_id, :string
    field :name, :string
    field :public_key, :binary
    field :framework, :string
    field :capabilities, {:array, :string}, default: []
    field :last_seen_at, :utc_datetime

    belongs_to :tenant, Hub.Auth.Tenant
    belongs_to :fleet, Hub.Auth.Fleet
    belongs_to :registered_via_key, Hub.Auth.ApiKey

    timestamps()
  end

  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [:agent_id, :name, :public_key, :framework, :capabilities, :last_seen_at, :tenant_id, :fleet_id, :registered_via_key_id])
    |> validate_required([:agent_id, :tenant_id, :fleet_id])
    |> unique_constraint(:agent_id)
  end
end
