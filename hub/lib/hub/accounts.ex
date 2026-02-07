defmodule Hub.Accounts do
  @moduledoc """
  Account management — registration, login, tenant lookup.

  On registration, auto-creates:
  - Tenant with email/password
  - Default fleet
  - Admin API key (returned to user once)
  """

  import Ecto.Query
  alias Hub.Repo
  alias Hub.Auth.{Tenant, Fleet}

  @doc """
  Register a new tenant with email + password.
  Returns `{:ok, %{tenant, fleet, admin_key}}` or `{:error, changeset}`.
  """
  def register(attrs) do
    Repo.transaction(fn ->
      # Create tenant
      changeset = Tenant.registration_changeset(%Tenant{}, attrs)

      case Repo.insert(changeset) do
        {:ok, tenant} ->
          # Create default fleet
          {:ok, fleet} =
            %Fleet{}
            |> Ecto.Changeset.change(%{tenant_id: tenant.id, name: "default"})
            |> Repo.insert()

          # Generate admin API key
          {:ok, raw_key, _api_key} = Hub.Auth.generate_api_key("admin", tenant.id, fleet.id)

          %{tenant: tenant, fleet: fleet, admin_key: raw_key}

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Authenticate by email + password.
  Returns `{:ok, tenant}` or `{:error, :invalid_credentials}`.
  """
  def login(email, password) when is_binary(email) and is_binary(password) do
    tenant = Repo.one(from t in Tenant, where: t.email == ^email)

    if tenant && Tenant.valid_password?(tenant, password) do
      {:ok, tenant}
    else
      # Constant-time comparison even when no user found
      Bcrypt.no_user_verify()
      {:error, :invalid_credentials}
    end
  end

  @doc "Get tenant by ID."
  def get_tenant(id), do: Repo.get(Tenant, id)

  @doc "Get tenant by email."
  def get_tenant_by_email(email), do: Repo.one(from t in Tenant, where: t.email == ^email)
end
