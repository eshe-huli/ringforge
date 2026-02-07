defmodule Hub.Accounts do
  @moduledoc """
  Account management — registration, login, tenant lookup.

  On registration, auto-creates:
  - Tenant with email/password
  - Default fleet
  - Admin API key (returned to user once)

  Supports email/password, social login (GitHub/Google), and magic link auth.
  """

  import Ecto.Query
  alias Hub.Repo
  alias Hub.Auth.{Tenant, Fleet, MagicLink}

  @magic_link_ttl_minutes 15

  # ── Email/Password Registration ───────────────────────────

  @doc """
  Register a new tenant with email + password.
  Returns `{:ok, %{tenant, fleet, admin_key}}` or `{:error, changeset}`.
  """
  def register(attrs) do
    Repo.transaction(fn ->
      changeset = Tenant.registration_changeset(%Tenant{}, attrs)

      case Repo.insert(changeset) do
        {:ok, tenant} ->
          {:ok, fleet} = create_default_fleet(tenant.id)
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
      Bcrypt.no_user_verify()
      {:error, :invalid_credentials}
    end
  end

  # ── Social Login (GitHub / Google) ────────────────────────

  @doc """
  Find or create a tenant from a social login callback.

  If a tenant with the same email exists, link the social ID.
  Otherwise, create a new tenant with social auth fields.

  Returns `{:ok, tenant}`.
  """
  def find_or_create_social(provider, %{email: email, name: name} = info) when provider in [:github, :google] do
    case get_tenant_by_email(email) do
      %Tenant{} = tenant ->
        # Link social ID to existing tenant
        link_attrs = social_link_attrs(provider, info)
        tenant |> Tenant.social_changeset(link_attrs) |> Repo.update()

      nil ->
        # Create new tenant via social login
        Repo.transaction(fn ->
          attrs =
            %{name: name || email, email: email, auth_provider: Atom.to_string(provider)}
            |> Map.merge(social_link_attrs(provider, info))

          changeset = Tenant.social_registration_changeset(%Tenant{}, attrs)

          case Repo.insert(changeset) do
            {:ok, tenant} ->
              {:ok, _fleet} = create_default_fleet(tenant.id)
              tenant

            {:error, changeset} ->
              Repo.rollback(changeset)
          end
        end)
    end
  end

  defp social_link_attrs(:github, info) do
    %{
      github_id: to_string(Map.get(info, :uid, "")),
      github_username: Map.get(info, :nickname, ""),
      auth_provider: "github"
    }
  end

  defp social_link_attrs(:google, info) do
    %{
      google_id: to_string(Map.get(info, :uid, "")),
      auth_provider: "google"
    }
  end

  # ── Magic Link ────────────────────────────────────────────

  @doc """
  Creates a magic link token for the given email.

  Returns `{:ok, raw_token}` — the raw token is logged to console
  (email sending can be wired later). The hashed token is stored in DB.
  """
  def create_magic_link(email) when is_binary(email) do
    # Clean up any existing tokens for this email
    from(m in MagicLink, where: m.email == ^email) |> Repo.delete_all()

    raw_token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    token_hash = hash_token(raw_token)
    expires_at = DateTime.utc_now() |> DateTime.add(@magic_link_ttl_minutes * 60, :second) |> DateTime.truncate(:second)

    attrs = %{
      token_hash: token_hash,
      email: email,
      expires_at: expires_at
    }

    case %MagicLink{} |> MagicLink.changeset(attrs) |> Repo.insert() do
      {:ok, _} -> {:ok, raw_token}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Verifies a magic link token.

  Finds the matching token, checks expiry, deletes it, and returns the tenant.
  Creates a new tenant if no account exists for the email.

  Returns `{:ok, tenant}` or `{:error, :invalid_token}`.
  """
  def verify_magic_link(raw_token) when is_binary(raw_token) do
    token_hash = hash_token(raw_token)
    now = DateTime.utc_now()

    query =
      from m in MagicLink,
        where: m.token_hash == ^token_hash,
        where: m.expires_at > ^now

    case Repo.one(query) do
      nil ->
        {:error, :invalid_token}

      %MagicLink{email: email} = link ->
        # Delete the token (single-use)
        Repo.delete(link)

        # Find or create tenant by email
        case get_tenant_by_email(email) do
          %Tenant{} = tenant ->
            {:ok, tenant}

          nil ->
            # Auto-create tenant from magic link
            Repo.transaction(fn ->
              attrs = %{name: email, email: email, auth_provider: "magic_link"}
              changeset = Tenant.social_registration_changeset(%Tenant{}, attrs)

              case Repo.insert(changeset) do
                {:ok, tenant} ->
                  {:ok, _fleet} = create_default_fleet(tenant.id)
                  tenant

                {:error, changeset} ->
                  Repo.rollback(changeset)
              end
            end)
        end
    end
  end

  def verify_magic_link(_), do: {:error, :invalid_token}

  # ── Lookups ───────────────────────────────────────────────

  @doc "Get tenant by ID."
  def get_tenant(id), do: Repo.get(Tenant, id)

  @doc "Get tenant by email."
  def get_tenant_by_email(email), do: Repo.one(from t in Tenant, where: t.email == ^email)

  @doc "Get tenant by GitHub ID."
  def get_tenant_by_github_id(github_id) do
    Repo.one(from t in Tenant, where: t.github_id == ^github_id)
  end

  @doc "Get tenant by Google ID."
  def get_tenant_by_google_id(google_id) do
    Repo.one(from t in Tenant, where: t.google_id == ^google_id)
  end

  # ── Helpers ───────────────────────────────────────────────

  defp create_default_fleet(tenant_id) do
    %Fleet{}
    |> Ecto.Changeset.change(%{tenant_id: tenant_id, name: "default"})
    |> Repo.insert()
  end

  defp hash_token(token) do
    :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
  end
end
