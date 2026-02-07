defmodule Hub.Schemas.ProviderCredential do
  @moduledoc """
  Schema for cloud provider credentials.

  Stores encrypted API tokens/keys for cloud providers (Hetzner, DigitalOcean, Contabo, AWS).
  All operations are tenant-scoped for strict isolation.
  Credentials are encrypted at rest using AES-256-GCM.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_providers ~w(hetzner digitalocean contabo aws)

  schema "provider_credentials" do
    field :provider, :string
    field :name, :string
    field :credentials, :map
    field :active, :boolean, default: true

    belongs_to :tenant, Hub.Auth.Tenant

    timestamps()
  end

  @required_fields ~w(provider name credentials tenant_id)a
  @optional_fields ~w(active)a

  def changeset(credential, attrs) do
    credential
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:provider, @valid_providers)
    |> validate_length(:name, min: 1, max: 100)
    |> foreign_key_constraint(:tenant_id)
  end

  def valid_providers, do: @valid_providers
end
