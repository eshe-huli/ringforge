defmodule Hub.AuthController do
  @moduledoc """
  Handles OAuth callbacks (GitHub, Google) and magic link authentication.

  Routes:
  - GET /auth/:provider         — redirect to OAuth provider (via Ueberauth)
  - GET /auth/:provider/callback — handle OAuth callback
  - POST /auth/magic-link       — send magic link email
  - GET /auth/magic-link/:token — verify magic link and log in
  """
  use Phoenix.Controller, formats: [:html]
  import Plug.Conn

  plug Ueberauth when action in [:request, :callback]

  alias Hub.Accounts
  alias Hub.Invites

  # ── OAuth Callback (GitHub / Google) ──────────────────────

  @doc "Ueberauth callback — find or create tenant, or handle failure."
  def callback(%{assigns: %{ueberauth_auth: auth}} = conn, %{"provider" => provider}) do
    email = get_email(auth)
    name = get_name(auth)
    uid = to_string(auth.uid)

    info = %{
      email: email,
      name: name,
      uid: uid,
      nickname: get_in(auth.info, [Access.key(:nickname)]) || ""
    }

    provider_atom = String.to_existing_atom(provider)

    # Check invite-only mode for new users
    if Invites.invite_only?() && is_nil(Accounts.get_tenant_by_email(email)) do
      conn
      |> redirect(to: "/dashboard?error=#{URI.encode("Registration requires an invite code. Sign up via email first.")}&tab=register")
    else
      case Accounts.find_or_create_social(provider_atom, info) do
        {:ok, tenant} ->
          conn
          |> put_session(:tenant_id, tenant.id)
          |> redirect(to: "/dashboard")

        {:error, _reason} ->
          conn
          |> redirect(to: "/dashboard?error=#{URI.encode("Authentication failed. Please try again.")}&tab=login")
      end
    end
  end

  def callback(%{assigns: %{ueberauth_failure: _failure}} = conn, _params) do
    conn
    |> redirect(to: "/dashboard?error=#{URI.encode("Authentication failed. Please try again.")}&tab=login")
  end

  # ── Magic Link: Send ──────────────────────────────────────

  @doc "POST /auth/magic-link — generate and 'send' magic link."
  def magic_link_send(conn, %{"email" => email}) do
    email = String.trim(email)

    if email == "" do
      conn
      |> redirect(to: "/dashboard?error=#{URI.encode("Email is required")}&tab=login")
    else
      # Check invite-only mode for new users
      if Invites.invite_only?() && is_nil(Accounts.get_tenant_by_email(email)) do
        conn
        |> redirect(to: "/dashboard?error=#{URI.encode("Registration requires an invite code. Sign up via email first.")}&tab=register")
      else
        case Accounts.create_magic_link(email) do
          {:ok, raw_token} ->
            # Log magic link to console (email integration wired later)
            magic_url = "#{Hub.Endpoint.url()}/auth/magic-link/#{raw_token}"

            require Logger
            Logger.info("""
            [MagicLink] Login link for #{email}:
            #{magic_url}
            """)

            conn
            |> redirect(to: "/dashboard?error=#{URI.encode("Magic link sent! Check your email (or server logs in dev).")}&tab=login")

          {:error, _} ->
            conn
            |> redirect(to: "/dashboard?error=#{URI.encode("Failed to create magic link")}&tab=login")
        end
      end
    end
  end

  # ── Magic Link: Verify ────────────────────────────────────

  @doc "GET /auth/magic-link/:token — verify token and log in."
  def magic_link_verify(conn, %{"token" => token}) do
    case Accounts.verify_magic_link(token) do
      {:ok, tenant} ->
        conn
        |> put_session(:tenant_id, tenant.id)
        |> redirect(to: "/dashboard")

      {:error, _} ->
        conn
        |> redirect(to: "/dashboard?error=#{URI.encode("Invalid or expired magic link")}&tab=login")
    end
  end

  # ── Ueberauth request phase (handled automatically) ──────

  def request(conn, _params) do
    # Ueberauth handles the redirect automatically
    conn
  end

  # ── Helpers ───────────────────────────────────────────────

  defp get_email(%{info: %{email: email}}) when is_binary(email) and email != "", do: email
  defp get_email(%{info: %{emails: [%{value: email} | _]}}), do: email
  defp get_email(_), do: nil

  defp get_name(%{info: %{name: name}}) when is_binary(name) and name != "", do: name
  defp get_name(%{info: %{nickname: nick}}) when is_binary(nick) and nick != "", do: nick
  defp get_name(_), do: nil
end
