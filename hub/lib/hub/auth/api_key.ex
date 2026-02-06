defmodule Hub.Auth.ApiKey do
  @moduledoc """
  Schema for API keys — used for agent registration and authentication.

  Keys are stored as SHA-256 hashes. The raw key is only returned once
  at creation time in the format `rf_{type}_{base62(32)}`.
  The `key_prefix` (first 8 chars) is stored for identification.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "api_keys" do
    field :key_hash, :string
    field :key_prefix, :string
    field :type, :string
    field :permissions, {:array, :string}, default: []
    field :expires_at, :utc_datetime
    field :revoked_at, :utc_datetime

    belongs_to :tenant, Hub.Auth.Tenant
    belongs_to :fleet, Hub.Auth.Fleet

    timestamps()
  end

  def changeset(api_key, attrs) do
    api_key
    |> cast(attrs, [:key_hash, :key_prefix, :type, :permissions, :expires_at, :revoked_at, :tenant_id, :fleet_id])
    |> validate_required([:key_hash, :key_prefix, :type, :tenant_id])
    |> validate_inclusion(:type, ["live", "test", "admin"])
  end
end
