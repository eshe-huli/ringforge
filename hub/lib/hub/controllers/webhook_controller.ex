defmodule Hub.WebhookController do
  @moduledoc """
  Handles incoming Stripe webhooks.

  Verifies the webhook signature using the STRIPE_WEBHOOK_SECRET,
  then dispatches to the appropriate handler in Hub.Billing.
  """
  use Phoenix.Controller, formats: [:json]

  require Logger

  alias Hub.Billing

  @doc """
  POST /webhooks/stripe

  Reads the raw body from `conn.assigns[:raw_body]` (set by a body-reading plug),
  verifies the Stripe signature, and dispatches the event.
  """
  def stripe(conn, _params) do
    with {:ok, raw_body} <- get_raw_body(conn),
         {:ok, event} <- verify_webhook(raw_body, conn) do
      handle_event(event)
      json(conn, %{received: true})
    else
      {:error, :no_raw_body} ->
        Logger.warning("[Webhook] No raw body available for Stripe webhook")

        conn
        |> put_status(400)
        |> json(%{error: "missing body"})

      {:error, :invalid_signature} ->
        Logger.warning("[Webhook] Invalid Stripe webhook signature")

        conn
        |> put_status(401)
        |> json(%{error: "invalid signature"})

      {:error, reason} ->
        Logger.error("[Webhook] Stripe webhook error: #{inspect(reason)}")

        conn
        |> put_status(400)
        |> json(%{error: "webhook error"})
    end
  end

  # ── Private ────────────────────────────────────────────────

  defp get_raw_body(conn) do
    case conn.assigns[:raw_body] do
      body when is_binary(body) and body != "" -> {:ok, body}
      _ -> {:error, :no_raw_body}
    end
  end

  defp verify_webhook(raw_body, conn) do
    webhook_secret = Application.get_env(:hub, :stripe, [])[:webhook_secret]

    signature =
      conn
      |> Plug.Conn.get_req_header("stripe-signature")
      |> List.first()

    cond do
      is_nil(webhook_secret) or webhook_secret == "" ->
        Logger.warning("[Webhook] No STRIPE_WEBHOOK_SECRET configured — skipping verification")
        # In development without a secret, just decode the JSON
        case Jason.decode(raw_body) do
          {:ok, data} -> {:ok, construct_event(data)}
          _ -> {:error, :invalid_json}
        end

      is_nil(signature) ->
        {:error, :invalid_signature}

      true ->
        case Stripe.Webhook.construct_event(raw_body, signature, webhook_secret) do
          {:ok, event} -> {:ok, event}
          {:error, _} -> {:error, :invalid_signature}
        end
    end
  end

  defp construct_event(%{"type" => type, "data" => %{"object" => object}}) do
    %Stripe.Event{type: type, data: %{object: object}}
  end

  defp construct_event(data), do: %Stripe.Event{type: data["type"], data: %{object: data}}

  defp handle_event(%{type: "checkout.session.completed", data: %{object: session}}) do
    Logger.info("[Webhook] checkout.session.completed for #{inspect(session.customer)}")

    # Retrieve the full subscription from Stripe and sync
    case Stripe.Subscription.retrieve(session.subscription) do
      {:ok, subscription} -> Billing.sync_subscription(subscription)
      {:error, err} -> Logger.error("[Webhook] Failed to retrieve subscription: #{inspect(err)}")
    end
  end

  defp handle_event(%{type: "customer.subscription.updated", data: %{object: subscription}}) do
    Logger.info("[Webhook] customer.subscription.updated: #{subscription.id}")
    Billing.sync_subscription(subscription)
  end

  defp handle_event(%{type: "customer.subscription.deleted", data: %{object: subscription}}) do
    Logger.info("[Webhook] customer.subscription.deleted: #{subscription.id}")
    Billing.handle_subscription_deleted(subscription)
  end

  defp handle_event(%{type: "invoice.paid", data: %{object: invoice}}) do
    Logger.info("[Webhook] invoice.paid: #{invoice.id}")
    # Payment confirmed — subscription is already synced via subscription.updated
    :ok
  end

  defp handle_event(%{type: "invoice.payment_failed", data: %{object: invoice}}) do
    Logger.warning("[Webhook] invoice.payment_failed: #{invoice.id}")
    Billing.handle_payment_failed(invoice)
  end

  defp handle_event(%{type: type}) do
    Logger.debug("[Webhook] Unhandled Stripe event: #{type}")
    :ok
  end
end
