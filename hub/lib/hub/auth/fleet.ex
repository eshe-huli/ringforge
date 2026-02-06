defmodule Hub.Auth.Fleet do
  @moduledoc """
  Schema for fleets — logical groupings of agents within a tenant.

  Each fleet belongs to a tenant and has a unique name within that tenant.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "fleets" do
    field :name, :string, default: "default"

    belongs_to :tenant, Hub.Auth.Tenant
    has_many :agents, Hub.Auth.Agent
    has_many :api_keys, Hub.Auth.ApiKey

    timestamps()
  end

  def changeset(fleet, attrs) do
    fleet
    |> cast(attrs, [:name, :tenant_id])
    |> validate_required([:tenant_id])
    |> unique_constraint([:tenant_id, :name])
  end
end
