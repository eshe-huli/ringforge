defmodule Hub.Auth.Tenant do
  @moduledoc """
  Schema for tenants — the top-level organizational unit.

  Each tenant has a name and a plan (defaulting to "free").
  Tenants own fleets, API keys, and agents.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "tenants" do
    field :name, :string
    field :plan, :string, default: "free"

    has_many :fleets, Hub.Auth.Fleet
    has_many :api_keys, Hub.Auth.ApiKey
    has_many :agents, Hub.Auth.Agent

    timestamps()
  end

  def changeset(tenant, attrs) do
    tenant
    |> cast(attrs, [:name, :plan])
    |> validate_required([:name])
  end
end
