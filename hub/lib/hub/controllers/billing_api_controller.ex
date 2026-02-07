defmodule Hub.BillingApiController do
  @moduledoc """
  JSON API controller for billing operations.

  Authenticated via the `:admin_auth` pipeline (API key or session).
  Returns JSON responses for programmatic billing management.
  """
  use Phoenix.Controller, formats: [:json]

  alias Hub.Repo
  alias Hub.Auth.Tenant
  alias Hub.Billing
  alias Hub.Quota

  @doc """
  GET /api/v1/billing/plans

  Returns all available plans with limits, features, and pricing.
  No authentication required — this is public info.
  """
  def plans(conn, _params) do
    plans = Billing.plans_info()

    json(conn, %{
      plans: Map.new(plans, fn {key, plan} ->
        {key, %{
          name: plan.name,
          price: plan.price,
          price_label: plan.price_label,
          limits: serialize_limits(plan.limits),
          features: plan.features
        }}
      end)
    })
  end

  @doc """
  GET /api/v1/billing/subscription

  Returns the current subscription info for the authenticated tenant.
  """
  def subscription(conn, _params) do
    tenant_id = conn.assigns[:tenant_id]

    case Billing.get_subscription(tenant_id) do
      nil ->
        tenant = Repo.get!(Tenant, tenant_id)
        json(conn, %{
          subscription: nil,
          plan: tenant.plan || "free",
          limits: serialize_limits(Quota.get_plan_limits(tenant.plan || "free")),
          features: Quota.plan_features(tenant.plan || "free")
        })

      sub ->
        json(conn, %{
          subscription: %{
            id: sub.id,
            plan: sub.plan,
            status: sub.status,
            stripe_subscription_id: sub.stripe_subscription_id,
            current_period_start: sub.current_period_start,
            current_period_end: sub.current_period_end,
            canceled_at: sub.canceled_at,
            trial_ends_at: sub.trial_ends_at
          },
          plan: sub.plan,
          limits: serialize_limits(Quota.get_plan_limits(sub.plan)),
          features: Quota.plan_features(sub.plan)
        })
    end
  end

  @doc """
  POST /api/v1/billing/checkout

  Creates a Stripe Checkout session and returns the URL.
  Expects `{"plan": "pro" | "scale" | "enterprise"}`.
  """
  def checkout(conn, %{"plan" => plan}) when plan in ~w(pro scale enterprise) do
    tenant = Repo.get!(Tenant, conn.assigns[:tenant_id])

    case Billing.create_checkout_session(tenant, plan) do
      {:ok, url} ->
        json(conn, %{checkout_url: url})

      {:error, :no_price_configured} ->
        conn
        |> put_status(422)
        |> json(%{error: "No Stripe price configured for plan: #{plan}"})

      {:error, :stripe_error} ->
        conn
        |> put_status(502)
        |> json(%{error: "Failed to create checkout session"})

      {:error, reason} ->
        conn
        |> put_status(422)
        |> json(%{error: "Checkout failed: #{inspect(reason)}"})
    end
  end

  def checkout(conn, _params) do
    conn
    |> put_status(400)
    |> json(%{error: "Invalid or missing plan. Valid plans: pro, scale, enterprise"})
  end

  @doc """
  POST /api/v1/billing/portal

  Creates a Stripe Customer Portal session and returns the URL.
  """
  def portal(conn, _params) do
    tenant = Repo.get!(Tenant, conn.assigns[:tenant_id])

    case Billing.create_portal_session(tenant) do
      {:ok, url} ->
        json(conn, %{portal_url: url})

      {:error, :stripe_error} ->
        conn
        |> put_status(502)
        |> json(%{error: "Failed to create portal session. Do you have a Stripe customer?"})

      {:error, reason} ->
        conn
        |> put_status(422)
        |> json(%{error: "Portal failed: #{inspect(reason)}"})
    end
  end

  # ── Private ────────────────────────────────────────────────

  defp serialize_limits(limits) when is_map(limits) do
    Map.new(limits, fn
      {k, :unlimited} -> {k, "unlimited"}
      {k, v} -> {k, v}
    end)
  end
end
