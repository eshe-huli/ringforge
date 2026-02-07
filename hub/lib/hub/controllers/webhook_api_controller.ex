defmodule Hub.WebhookApiController do
  @moduledoc """
  JSON API controller for managing outbound webhooks.

  Authenticated via the `:admin_auth` pipeline (API key or session).
  All operations are tenant-scoped.
  """
  use Phoenix.Controller, formats: [:json]

  alias Hub.Repo
  alias Hub.Auth.Tenant
  alias Hub.Webhooks

  @doc "POST /api/v1/webhooks — Create a webhook endpoint."
  def create(conn, params) do
    tenant = Repo.get!(Tenant, conn.assigns[:tenant_id])

    attrs = %{
      url: params["url"],
      events: params["events"] || [],
      fleet_id: params["fleet_id"],
      description: params["description"],
      active: Map.get(params, "active", true)
    }

    case Webhooks.create(tenant, attrs) do
      {:ok, webhook} ->
        conn
        |> put_status(201)
        |> json(%{
          webhook: serialize_webhook(webhook, show_secret: true)
        })

      {:error, :plan_not_allowed} ->
        conn
        |> put_status(403)
        |> json(%{error: "plan_not_allowed", message: "Webhooks are not available on the free plan. Upgrade to Pro or higher."})

      {:error, :webhook_limit_reached} ->
        conn
        |> put_status(422)
        |> json(%{error: "webhook_limit_reached", message: "Maximum number of webhooks reached for your plan."})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(422)
        |> json(%{error: "validation_failed", details: format_errors(changeset)})
    end
  end

  @doc "GET /api/v1/webhooks — List all webhooks."
  def index(conn, _params) do
    tenant = Repo.get!(Tenant, conn.assigns[:tenant_id])
    webhooks = Webhooks.list(tenant)

    json(conn, %{
      webhooks: Enum.map(webhooks, &serialize_webhook/1)
    })
  end

  @doc "GET /api/v1/webhooks/:id — Get a webhook with delivery log."
  def show(conn, %{"id" => id}) do
    tenant = Repo.get!(Tenant, conn.assigns[:tenant_id])

    case Webhooks.get(id, tenant) do
      {:ok, webhook} ->
        json(conn, %{
          webhook: serialize_webhook(webhook),
          deliveries: Enum.map(webhook.deliveries, &serialize_delivery/1)
        })

      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{error: "not_found", message: "Webhook not found"})
    end
  end

  @doc "PUT /api/v1/webhooks/:id — Update a webhook."
  def update(conn, %{"id" => id} = params) do
    tenant = Repo.get!(Tenant, conn.assigns[:tenant_id])

    attrs =
      %{}
      |> maybe_put(:url, params["url"])
      |> maybe_put(:events, params["events"])
      |> maybe_put(:fleet_id, params["fleet_id"])
      |> maybe_put(:description, params["description"])
      |> maybe_put(:active, params["active"])

    case Webhooks.update(id, tenant, attrs) do
      {:ok, webhook} ->
        json(conn, %{webhook: serialize_webhook(webhook)})

      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{error: "not_found", message: "Webhook not found"})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(422)
        |> json(%{error: "validation_failed", details: format_errors(changeset)})
    end
  end

  @doc "DELETE /api/v1/webhooks/:id — Delete a webhook."
  def delete(conn, %{"id" => id}) do
    tenant = Repo.get!(Tenant, conn.assigns[:tenant_id])

    case Webhooks.delete(id, tenant) do
      {:ok, _} ->
        json(conn, %{deleted: true})

      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{error: "not_found", message: "Webhook not found"})
    end
  end

  @doc "POST /api/v1/webhooks/:id/test — Send a test event."
  def test(conn, %{"id" => id}) do
    tenant = Repo.get!(Tenant, conn.assigns[:tenant_id])

    case Webhooks.get(id, tenant) do
      {:ok, webhook} ->
        # Dispatch a test event
        Hub.WebhookDispatcher.dispatch(
          "test.ping",
          %{"message" => "Test webhook delivery from RingForge", "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()},
          webhook.fleet_id
        )

        json(conn, %{sent: true, message: "Test event dispatched"})

      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{error: "not_found", message: "Webhook not found"})
    end
  end

  # ── Private ────────────────────────────────────────────────

  defp serialize_webhook(webhook, opts \\ []) do
    base = %{
      id: webhook.id,
      url: webhook.url,
      events: webhook.events,
      active: webhook.active,
      description: webhook.description,
      fleet_id: webhook.fleet_id,
      inserted_at: webhook.inserted_at,
      updated_at: webhook.updated_at
    }

    if Keyword.get(opts, :show_secret, false) do
      Map.put(base, :secret, webhook.secret)
    else
      base
    end
  end

  defp serialize_delivery(delivery) do
    %{
      id: delivery.id,
      event_type: delivery.event_type,
      status: delivery.status,
      attempt: delivery.attempt,
      response_status: delivery.response_status,
      delivered_at: delivery.delivered_at,
      next_retry_at: delivery.next_retry_at
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
