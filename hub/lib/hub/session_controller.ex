defmodule Hub.SessionController do
  @moduledoc """
  Handles session-based auth for the dashboard.
  POST /auth/register — create tenant, set session, redirect
  POST /auth/login — verify creds, set session, redirect
  GET  /auth/logout — clear session, redirect to /dashboard
  """
  use Phoenix.Controller, formats: [:html]
  import Plug.Conn

  alias Hub.Accounts

  def register(conn, %{"name" => name, "email" => email, "password" => password}) do
    case Accounts.register(%{name: name, email: email, password: password}) do
      {:ok, %{tenant: tenant}} ->
        conn
        |> put_session(:tenant_id, tenant.id)
        |> redirect(to: "/dashboard")

      {:error, changeset} ->
        error = format_changeset_error(changeset)
        conn
        |> redirect(to: "/dashboard?error=#{URI.encode(error)}&tab=register")
    end
  end

  def login(conn, %{"email" => email, "password" => password}) do
    case Accounts.login(email, password) do
      {:ok, tenant} ->
        conn
        |> put_session(:tenant_id, tenant.id)
        |> redirect(to: "/dashboard")

      {:error, :invalid_credentials} ->
        conn
        |> redirect(to: "/dashboard?error=#{URI.encode("Invalid email or password")}&tab=login")
    end
  end

  def api_key_login(conn, %{"key" => key}) do
    case Hub.Auth.validate_api_key(key) do
      {:ok, %{type: "admin", tenant_id: tenant_id}} ->
        conn
        |> put_session(:tenant_id, tenant_id)
        |> redirect(to: "/dashboard")

      {:ok, _} ->
        conn |> redirect(to: "/dashboard?error=#{URI.encode("Admin API key required")}&tab=apikey")

      {:error, _} ->
        conn |> redirect(to: "/dashboard?error=#{URI.encode("Invalid API key")}&tab=apikey")
    end
  end

  def logout(conn, _params) do
    conn
    |> clear_session()
    |> redirect(to: "/dashboard")
  end

  defp format_changeset_error(%Ecto.Changeset{} = cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map_join(". ", fn {field, msgs} ->
      "#{Phoenix.Naming.humanize(field)} #{Enum.join(msgs, ", ")}"
    end)
  end
  defp format_changeset_error(_), do: "Registration failed"
end
