defmodule Hub.Auth.Agent do
  @moduledoc """
  Schema for agents — individual AI agents registered to a tenant/fleet.

  Each agent has a unique `agent_id` (e.g. "ag_abc123"), an optional
  Ed25519 public key for challenge-response auth, and metadata about
  its framework and capabilities.

  Profile fields (avatar_url, description, tags, metadata, display_name)
  persist across reconnections, allowing agents to maintain identity.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agents" do
    field :agent_id, :string
    field :name, :string
    field :display_name, :string
    field :public_key, :binary
    field :framework, :string
    field :capabilities, {:array, :string}, default: []
    field :last_seen_at, :utc_datetime

    # Profile fields
    field :avatar_url, :string
    field :description, :string
    field :tags, {:array, :string}, default: []
    field :metadata, :map, default: %{}

    # Stats
    field :total_connections, :integer, default: 0
    field :total_messages, :integer, default: 0

    belongs_to :tenant, Hub.Auth.Tenant
    belongs_to :fleet, Hub.Auth.Fleet
    belongs_to :registered_via_key, Hub.Auth.ApiKey

    has_many :sessions, Hub.Auth.AgentSession

    timestamps()
  end

  @cast_fields [
    :agent_id, :name, :display_name, :public_key, :framework, :capabilities,
    :last_seen_at, :tenant_id, :fleet_id, :registered_via_key_id,
    :avatar_url, :description, :tags, :metadata,
    :total_connections, :total_messages
  ]

  @profile_fields [:display_name, :avatar_url, :description, :tags, :metadata]

  def changeset(agent, attrs) do
    agent
    |> cast(attrs, @cast_fields)
    |> validate_required([:agent_id, :tenant_id, :fleet_id])
    |> unique_constraint(:agent_id)
    |> unique_constraint([:name, :fleet_id], name: :agents_name_fleet_id_unique)
    |> validate_length(:display_name, max: 100)
    |> validate_length(:avatar_url, max: 2048)
    |> validate_length(:description, max: 2000)
  end

  @doc "Changeset limited to profile fields only."
  def profile_changeset(agent, attrs) do
    agent
    |> cast(attrs, @profile_fields)
    |> validate_length(:display_name, max: 100)
    |> validate_length(:avatar_url, max: 2048)
    |> validate_length(:description, max: 2000)
  end

  @doc "Convert agent to a profile map for API responses."
  def to_profile(%__MODULE__{} = agent) do
    %{
      agent_id: agent.agent_id,
      name: agent.name,
      display_name: agent.display_name,
      avatar_url: agent.avatar_url,
      description: agent.description,
      tags: agent.tags || [],
      metadata: agent.metadata || %{},
      framework: agent.framework,
      capabilities: agent.capabilities || [],
      total_connections: agent.total_connections || 0,
      total_messages: agent.total_messages || 0,
      last_seen_at: agent.last_seen_at && DateTime.to_iso8601(agent.last_seen_at),
      inserted_at: agent.inserted_at && NaiveDateTime.to_iso8601(agent.inserted_at)
    }
  end
end
