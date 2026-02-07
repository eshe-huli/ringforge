defmodule Hub.BillingController do
  @moduledoc """
  Simple controller for billing actions — redirects to Stripe Checkout or Portal.

  Session-authenticated (uses `:browser` pipeline with tenant_id in session).
  """
  use Phoenix.Controller, formats: [:html]

  alias Hub.Repo
  alias Hub.Auth.Tenant
  alias Hub.Billing

  @doc """
  POST /billing/checkout

  Creates a Stripe Checkout session and redirects the user.
  Expects `plan` param (pro, scale, enterprise).
  """
  def checkout(conn, %{"plan" => plan}) when plan in ~w(pro scale enterprise) do
    with tenant_id when is_binary(tenant_id) <- Plug.Conn.get_session(conn, :tenant_id),
         %Tenant{} = tenant <- Repo.get(Tenant, tenant_id),
         {:ok, url} <- Billing.create_checkout_session(tenant, plan) do
      redirect(conn, external: url)
    else
      nil ->
        conn
        |> put_flash(:error, "You must be logged in.")
        |> redirect(to: "/dashboard")

      {:error, reason} ->
        conn
        |> put_flash(:error, "Could not start checkout: #{inspect(reason)}")
        |> redirect(to: "/dashboard")
    end
  end

  def checkout(conn, _params) do
    conn
    |> put_flash(:error, "Invalid plan selected.")
    |> redirect(to: "/dashboard")
  end

  @doc """
  GET /billing/portal

  Creates a Stripe Customer Portal session and redirects the user
  to manage their subscription.
  """
  def portal(conn, _params) do
    with tenant_id when is_binary(tenant_id) <- Plug.Conn.get_session(conn, :tenant_id),
         %Tenant{} = tenant <- Repo.get(Tenant, tenant_id),
         {:ok, url} <- Billing.create_portal_session(tenant) do
      redirect(conn, external: url)
    else
      nil ->
        conn
        |> put_flash(:error, "You must be logged in.")
        |> redirect(to: "/dashboard")

      {:error, :stripe_error} ->
        conn
        |> put_flash(:error, "Could not open billing portal. Do you have an active subscription?")
        |> redirect(to: "/dashboard")

      {:error, reason} ->
        conn
        |> put_flash(:error, "Billing portal error: #{inspect(reason)}")
        |> redirect(to: "/dashboard")
    end
  end
end
