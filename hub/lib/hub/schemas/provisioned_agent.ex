defmodule Hub.Schemas.ProvisionedAgent do
  @moduledoc """
  Schema for cloud-provisioned agents.

  Tracks servers provisioned on cloud providers to run RingForge agents.
  Includes provider metadata, status, cost tracking, and the auto-generated
  API key for the agent to connect to the fleet.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_statuses ~w(provisioning running stopped error destroyed)
  @valid_templates ~w(openclaw bare custom)

  schema "provisioned_agents" do
    field :provider, :string
    field :external_id, :string
    field :name, :string
    field :ip_address, :string
    field :status, :string, default: "provisioning"
    field :region, :string
    field :size, :string
    field :template, :string, default: "openclaw"
    field :agent_api_key, :string
    field :monthly_cost_cents, :integer, default: 0
    field :error_message, :string
    field :provisioned_at, :utc_datetime

    belongs_to :tenant, Hub.Auth.Tenant
    belongs_to :fleet, Hub.Auth.Fleet
    belongs_to :provider_credential, Hub.Schemas.ProviderCredential

    timestamps()
  end

  @required_fields ~w(provider name region size template agent_api_key tenant_id fleet_id provider_credential_id)a
  @optional_fields ~w(external_id ip_address status monthly_cost_cents error_message provisioned_at)a

  def changeset(agent, attrs) do
    agent
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_inclusion(:template, @valid_templates)
    |> validate_length(:name, min: 1, max: 100)
    |> foreign_key_constraint(:tenant_id)
    |> foreign_key_constraint(:fleet_id)
    |> foreign_key_constraint(:provider_credential_id)
  end

  def status_changeset(agent, attrs) do
    agent
    |> cast(attrs, [:status, :ip_address, :external_id, :error_message, :provisioned_at])
    |> validate_inclusion(:status, @valid_statuses)
  end

  def valid_statuses, do: @valid_statuses
  def valid_templates, do: @valid_templates
end
