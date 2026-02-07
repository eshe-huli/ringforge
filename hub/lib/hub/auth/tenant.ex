defmodule Hub.Auth.Tenant do
  @moduledoc """
  Schema for tenants — the top-level organizational unit.

  Each tenant has a name, plan, and optional email/password for dashboard login.
  Tenants own fleets, API keys, and agents.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "tenants" do
    field :name, :string
    field :plan, :string, default: "free"
    field :email, :string
    field :password_hash, :string
    field :stripe_customer_id, :string

    # Virtual field — never persisted
    field :password, :string, virtual: true

    has_many :fleets, Hub.Auth.Fleet
    has_many :api_keys, Hub.Auth.ApiKey
    has_many :agents, Hub.Auth.Agent
    has_one :subscription, Hub.Billing.Subscription

    timestamps()
  end

  def changeset(tenant, attrs) do
    tenant
    |> cast(attrs, [:name, :plan])
    |> validate_required([:name])
  end

  @doc "Changeset for registration with email + password."
  def registration_changeset(tenant, attrs) do
    tenant
    |> cast(attrs, [:name, :email, :password])
    |> validate_required([:name, :email, :password])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+\.[^\s]+$/, message: "must be a valid email")
    |> validate_length(:password, min: 8, message: "must be at least 8 characters")
    |> unique_constraint(:email)
    |> hash_password()
  end

  defp hash_password(changeset) do
    case get_change(changeset, :password) do
      nil -> changeset
      password ->
        changeset
        |> put_change(:password_hash, Bcrypt.hash_pwd_salt(password))
        |> delete_change(:password)
    end
  end

  @doc "Verify a plaintext password against the stored hash."
  def valid_password?(%__MODULE__{password_hash: hash}, password)
      when is_binary(hash) and is_binary(password) do
    Bcrypt.verify_pass(password, hash)
  end
  def valid_password?(_, _) do
    Bcrypt.no_user_verify()
    false
  end
end
