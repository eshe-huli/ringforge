defmodule Hub.Webhooks do
  @moduledoc """
  Context module for managing outbound webhooks.

  Provides CRUD operations for webhook endpoints, HMAC payload signing,
  and event delivery coordination. All operations are tenant-scoped.
  """

  import Ecto.Query

  alias Hub.Repo
  alias Hub.Schemas.Webhook
  alias Hub.Schemas.WebhookDelivery

  @max_webhooks %{
    "free" => 0,
    "pro" => 10,
    "scale" => 50,
    "enterprise" => 500
  }

  # ── CRUD ───────────────────────────────────────────────────

  @doc """
  Create a webhook endpoint for a tenant.
  Generates an HMAC secret automatically.
  Checks plan limits on webhook count.
  """
  def create(tenant, attrs) do
    plan = tenant.plan || "free"
    max = Map.get(@max_webhooks, plan, 0)

    if max == 0 do
      {:error, :plan_not_allowed}
    else
      current_count = count_webhooks(tenant.id)

      if current_count >= max do
        {:error, :webhook_limit_reached}
      else
        secret = generate_secret()

        %Webhook{}
        |> Webhook.changeset(Map.merge(attrs, %{tenant_id: tenant.id, secret: secret}))
        |> Repo.insert()
      end
    end
  end

  @doc "List all webhooks for a tenant."
  def list(tenant) do
    Webhook
    |> where([w], w.tenant_id == ^tenant.id)
    |> order_by([w], desc: w.inserted_at)
    |> Repo.all()
  end

  @doc "Get a single webhook by ID, scoped to tenant, with recent deliveries."
  def get(webhook_id, tenant) do
    case Repo.one(
           from w in Webhook,
             where: w.id == ^webhook_id and w.tenant_id == ^tenant.id
         ) do
      nil ->
        {:error, :not_found}

      webhook ->
        deliveries =
          WebhookDelivery
          |> where([d], d.webhook_id == ^webhook.id)
          |> order_by([d], desc: d.delivered_at)
          |> limit(50)
          |> Repo.all()

        {:ok, %{webhook | deliveries: deliveries}}
    end
  end

  @doc "Update a webhook, scoped to tenant."
  def update(webhook_id, tenant, attrs) do
    case Repo.one(from w in Webhook, where: w.id == ^webhook_id and w.tenant_id == ^tenant.id) do
      nil ->
        {:error, :not_found}

      webhook ->
        webhook
        |> Webhook.changeset(attrs)
        |> Repo.update()
    end
  end

  @doc "Delete a webhook, scoped to tenant."
  def delete(webhook_id, tenant) do
    case Repo.one(from w in Webhook, where: w.id == ^webhook_id and w.tenant_id == ^tenant.id) do
      nil ->
        {:error, :not_found}

      webhook ->
        Repo.delete(webhook)
    end
  end

  # ── Delivery ───────────────────────────────────────────────

  @doc """
  Find all matching webhooks for an event and enqueue delivery.
  Returns list of created delivery records.
  """
  def deliver(event_type, payload, fleet_id) do
    webhooks = find_matching_webhooks(event_type, fleet_id)

    Enum.map(webhooks, fn webhook ->
      delivery_id = Ecto.UUID.generate()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      delivery_payload = %{
        "id" => delivery_id,
        "event" => event_type,
        "timestamp" => DateTime.to_iso8601(now),
        "fleet_id" => fleet_id,
        "data" => payload
      }

      {:ok, delivery} =
        %WebhookDelivery{}
        |> WebhookDelivery.changeset(%{
          id: delivery_id,
          webhook_id: webhook.id,
          event_type: event_type,
          payload: delivery_payload,
          attempt: 1,
          delivered_at: now,
          status: "pending"
        })
        |> Repo.insert()

      {webhook, delivery}
    end)
  end

  @doc """
  Find matching webhooks for an event type and fleet.
  Matches webhooks that:
  - Are active
  - Subscribe to the given event type
  - Scope to the given fleet OR have no fleet restriction (fleet_id IS NULL)
  """
  def find_matching_webhooks(event_type, fleet_id) do
    query =
      from w in Webhook,
        where: w.active == true,
        where: ^event_type in w.events

    query =
      if fleet_id do
        from w in query,
          where: is_nil(w.fleet_id) or w.fleet_id == ^fleet_id
      else
        from w in query,
          where: is_nil(w.fleet_id)
      end

    Repo.all(query)
  end

  @doc "Update a delivery record after an attempt."
  def update_delivery(delivery, attrs) do
    delivery
    |> WebhookDelivery.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Clean up old delivery logs, keeping only the last 100 per webhook.
  """
  def cleanup_deliveries(webhook_id) do
    # Find the ID of the 100th newest delivery
    cutoff =
      from(d in WebhookDelivery,
        where: d.webhook_id == ^webhook_id,
        order_by: [desc: d.delivered_at],
        offset: 100,
        limit: 1,
        select: d.delivered_at
      )
      |> Repo.one()

    if cutoff do
      from(d in WebhookDelivery,
        where: d.webhook_id == ^webhook_id and d.delivered_at < ^cutoff
      )
      |> Repo.delete_all()
    end

    :ok
  end

  @doc """
  Get pending deliveries that are due for retry.
  """
  def pending_retries do
    now = DateTime.utc_now()

    from(d in WebhookDelivery,
      where: d.status == "pending" and not is_nil(d.next_retry_at) and d.next_retry_at <= ^now,
      preload: [:webhook]
    )
    |> Repo.all()
  end

  # ── Signing ────────────────────────────────────────────────

  @doc "Generate HMAC-SHA256 signature for a payload using the webhook secret."
  def sign_payload(payload, secret) when is_binary(payload) do
    :crypto.mac(:hmac, :sha256, secret, payload)
    |> Base.encode16(case: :lower)
  end

  def sign_payload(payload, secret) when is_map(payload) do
    payload
    |> Jason.encode!()
    |> sign_payload(secret)
  end

  # ── Private ────────────────────────────────────────────────

  defp count_webhooks(tenant_id) do
    Repo.one(from w in Webhook, where: w.tenant_id == ^tenant_id, select: count(w.id))
  end

  defp generate_secret do
    :crypto.strong_rand_bytes(32) |> Base.encode64(padding: false)
  end
end
