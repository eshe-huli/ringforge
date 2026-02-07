defmodule Hub.Billing do
  @moduledoc """
  Billing context — manages Stripe customers, checkout sessions,
  portal sessions, and subscription lifecycle.

  All Stripe price IDs and config are read from application config
  (set via environment variables).
  """

  require Logger

  import Ecto.Query

  alias Hub.Repo
  alias Hub.Auth.Tenant
  alias Hub.Billing.Subscription
  alias Hub.Quota

  # ── Config Helpers ─────────────────────────────────────────

  defp stripe_config, do: Application.get_env(:hub, :stripe, [])

  defp price_ids, do: stripe_config()[:price_ids] || %{}

  defp success_url, do: stripe_config()[:success_url] || "http://localhost:4000/dashboard?billing=success"

  defp cancel_url, do: stripe_config()[:cancel_url] || "http://localhost:4000/dashboard?billing=canceled"

  @doc """
  Maps a Stripe price ID to a plan name.
  Returns `nil` if no matching plan is found.
  """
  def plan_for_price(stripe_price_id) do
    price_ids()
    |> Enum.find_value(fn {plan, price_id} ->
      if price_id == stripe_price_id, do: plan
    end)
  end

  @doc """
  Returns the Stripe price ID for a plan name.
  """
  def price_for_plan(plan) do
    Map.get(price_ids(), plan)
  end

  # ── Customer Management ────────────────────────────────────

  @doc """
  Creates a Stripe customer for a tenant and stores the customer ID.

  If the tenant already has a `stripe_customer_id`, returns it without
  creating a new customer.
  """
  def create_customer(%Tenant{stripe_customer_id: cid} = tenant) when is_binary(cid) and cid != "" do
    {:ok, tenant}
  end

  def create_customer(%Tenant{} = tenant) do
    params = %{
      name: tenant.name,
      email: tenant.email,
      metadata: %{tenant_id: tenant.id}
    }

    case Stripe.Customer.create(params) do
      {:ok, %Stripe.Customer{id: customer_id}} ->
        tenant
        |> Ecto.Changeset.change(%{stripe_customer_id: customer_id})
        |> Repo.update()

      {:error, %Stripe.Error{} = error} ->
        Logger.error("[Hub.Billing] Failed to create Stripe customer: #{inspect(error)}")
        {:error, :stripe_error}
    end
  end

  # ── Checkout & Portal ──────────────────────────────────────

  @doc """
  Creates a Stripe Checkout session for upgrading to a paid plan.

  Returns `{:ok, checkout_url}` on success.
  """
  def create_checkout_session(%Tenant{} = tenant, plan) when plan in ~w(pro scale enterprise) do
    with {:ok, tenant} <- ensure_customer(tenant),
         {:ok, price_id} <- get_price_id(plan) do
      params = %{
        customer: tenant.stripe_customer_id,
        mode: "subscription",
        line_items: [%{price: price_id, quantity: 1}],
        success_url: success_url(),
        cancel_url: cancel_url(),
        client_reference_id: tenant.id,
        metadata: %{tenant_id: tenant.id, plan: plan}
      }

      case Stripe.Checkout.Session.create(params) do
        {:ok, %{url: url}} ->
          {:ok, url}

        {:error, %Stripe.Error{} = error} ->
          Logger.error("[Hub.Billing] Checkout session failed: #{inspect(error)}")
          {:error, :stripe_error}
      end
    end
  end

  def create_checkout_session(_tenant, _plan), do: {:error, :invalid_plan}

  @doc """
  Creates a Stripe Customer Portal session so the user can manage
  their subscription, payment methods, and invoices.

  Returns `{:ok, portal_url}` on success.
  """
  def create_portal_session(%Tenant{} = tenant) do
    with {:ok, tenant} <- ensure_customer(tenant) do
      params = %{
        customer: tenant.stripe_customer_id,
        return_url: success_url()
      }

      case Stripe.BillingPortal.Session.create(params) do
        {:ok, %{url: url}} ->
          {:ok, url}

        {:error, %Stripe.Error{} = error} ->
          Logger.error("[Hub.Billing] Portal session failed: #{inspect(error)}")
          {:error, :stripe_error}
      end
    end
  end

  # ── Subscription Queries ───────────────────────────────────

  @doc "Get the current subscription for a tenant."
  def get_subscription(tenant_id) do
    Repo.one(
      from s in Subscription,
        where: s.tenant_id == ^tenant_id,
        order_by: [desc: s.updated_at],
        limit: 1
    )
  end

  @doc """
  Returns the effective plan for a tenant.
  If no active subscription exists, returns "free".
  """
  def effective_plan(tenant_id) do
    case get_subscription(tenant_id) do
      %Subscription{status: status, plan: plan} when status in ~w(active trialing) ->
        plan

      _ ->
        "free"
    end
  end

  # ── Webhook Sync ───────────────────────────────────────────

  @doc """
  Upserts a local subscription record from a Stripe subscription object.
  Called from webhook handlers when subscription state changes.
  """
  def sync_subscription(%Stripe.Subscription{} = stripe_sub) do
    tenant = find_tenant_by_customer(stripe_sub.customer)

    unless tenant do
      Logger.warning("[Hub.Billing] No tenant found for Stripe customer #{stripe_sub.customer}")
      {:error, :tenant_not_found}
    else
      plan = resolve_plan(stripe_sub)
      status = to_string(stripe_sub.status)

      attrs = %{
        tenant_id: tenant.id,
        stripe_customer_id: stripe_sub.customer,
        stripe_subscription_id: stripe_sub.id,
        stripe_price_id: get_subscription_price_id(stripe_sub),
        plan: plan,
        status: status,
        current_period_start: from_unix(stripe_sub.current_period_start),
        current_period_end: from_unix(stripe_sub.current_period_end),
        trial_ends_at: from_unix(stripe_sub.trial_end),
        canceled_at: from_unix(stripe_sub.canceled_at)
      }

      existing =
        Repo.one(
          from s in Subscription,
            where: s.stripe_subscription_id == ^stripe_sub.id
        )

      result =
        case existing do
          nil ->
            %Subscription{}
            |> Subscription.changeset(attrs)
            |> Repo.insert()

          sub ->
            sub
            |> Subscription.changeset(attrs)
            |> Repo.update()
        end

      case result do
        {:ok, subscription} ->
          # Sync plan to tenant record and update quotas
          sync_tenant_plan(tenant, plan, status)
          {:ok, subscription}

        {:error, changeset} ->
          Logger.error("[Hub.Billing] Failed to sync subscription: #{inspect(changeset.errors)}")
          {:error, changeset}
      end
    end
  end

  @doc """
  Handle subscription deletion — downgrade tenant to free.
  """
  def handle_subscription_deleted(%Stripe.Subscription{} = stripe_sub) do
    case Repo.one(from s in Subscription, where: s.stripe_subscription_id == ^stripe_sub.id) do
      nil ->
        :ok

      sub ->
        sub
        |> Subscription.changeset(%{status: "canceled", canceled_at: DateTime.utc_now()})
        |> Repo.update()

        # Downgrade to free
        if tenant = Repo.get(Tenant, sub.tenant_id) do
          sync_tenant_plan(tenant, "free", "canceled")
        end

        :ok
    end
  end

  @doc """
  Mark subscription as past_due when payment fails.
  """
  def handle_payment_failed(stripe_invoice) do
    sub_id = stripe_invoice.subscription

    if sub_id do
      case Repo.one(from s in Subscription, where: s.stripe_subscription_id == ^sub_id) do
        nil -> :ok
        sub ->
          sub
          |> Subscription.changeset(%{status: "past_due"})
          |> Repo.update()
      end
    else
      :ok
    end
  end

  # ── Private Helpers ────────────────────────────────────────

  defp ensure_customer(%Tenant{stripe_customer_id: cid} = tenant)
       when is_binary(cid) and cid != "" do
    {:ok, tenant}
  end

  defp ensure_customer(%Tenant{} = tenant) do
    create_customer(tenant)
  end

  defp get_price_id(plan) do
    case price_for_plan(plan) do
      nil -> {:error, :no_price_configured}
      price_id -> {:ok, price_id}
    end
  end

  defp find_tenant_by_customer(customer_id) when is_binary(customer_id) do
    Repo.one(from t in Tenant, where: t.stripe_customer_id == ^customer_id)
  end

  defp find_tenant_by_customer(_), do: nil

  defp resolve_plan(%Stripe.Subscription{} = stripe_sub) do
    price_id = get_subscription_price_id(stripe_sub)
    plan_for_price(price_id) || "free"
  end

  defp get_subscription_price_id(%Stripe.Subscription{items: %{data: [item | _]}}) do
    item.price.id
  rescue
    _ -> nil
  end

  defp get_subscription_price_id(_), do: nil

  defp from_unix(nil), do: nil
  defp from_unix(ts) when is_integer(ts), do: DateTime.from_unix!(ts)
  defp from_unix(_), do: nil

  defp sync_tenant_plan(%Tenant{} = tenant, plan, status) do
    effective = if status in ~w(active trialing), do: plan, else: "free"

    # Update tenant plan field
    tenant
    |> Ecto.Changeset.change(%{plan: effective})
    |> Repo.update()

    # Update quota limits
    Quota.set_plan_limits(tenant.id, effective)

    Logger.info("[Hub.Billing] Tenant #{tenant.id} plan synced to '#{effective}'")
  end
end
