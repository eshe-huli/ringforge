defmodule Hub.WebhookDispatcher do
  @moduledoc """
  Dispatches webhook events to registered endpoints.

  Uses Task.Supervisor to send HTTP POST requests to webhook URLs.
  Handles retries with exponential backoff (attempt 1 immediately,
  attempt 2 after 30s, attempt 3 after 5min).

  Subscribes to EventBus topics to receive fleet events and matches
  them against registered webhooks.

  Uses hackney (already in deps) for HTTP requests.
  """

  use GenServer

  require Logger

  alias Hub.Webhooks

  @default_config %{
    max_retries: 3,
    timeout_ms: 10_000,
    retry_delays: [30_000, 300_000]
  }

  # ── Event type mapping ─────────────────────────────────────

  # Maps internal event kinds/actions to webhook event types
  @event_mapping %{
    "join" => "agent.connected",
    "joined" => "agent.connected",
    "leave" => "agent.disconnected",
    "left" => "agent.disconnected",
    "task_started" => "task.submitted",
    "task_completed" => "task.completed",
    "task_failed" => "task.failed",
    "file_shared" => "file.shared",
    "file_deleted" => "file.deleted"
  }

  # ── Public API ─────────────────────────────────────────────

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Dispatch an event to matching webhooks."
  def dispatch(event_type, payload, fleet_id) do
    GenServer.cast(__MODULE__, {:dispatch, event_type, payload, fleet_id})
  end

  @doc "Dispatch an event derived from the internal event bus format."
  def dispatch_event(kind, payload, fleet_id) do
    event_type = Map.get(@event_mapping, kind, kind)
    dispatch(event_type, payload, fleet_id)
  end

  @doc "Process pending retries."
  def process_retries do
    GenServer.cast(__MODULE__, :process_retries)
  end

  # ── GenServer Callbacks ────────────────────────────────────

  @impl true
  def init(_opts) do
    # Start the Task.Supervisor for async deliveries
    {:ok, sup} = Task.Supervisor.start_link(name: Hub.WebhookTaskSupervisor)

    # Schedule periodic retry processing
    Process.send_after(self(), :retry_tick, 15_000)

    {:ok, %{task_supervisor: sup}}
  end

  @impl true
  def handle_cast({:dispatch, event_type, payload, fleet_id}, state) do
    deliveries = Webhooks.deliver(event_type, payload, fleet_id)

    for {webhook, delivery} <- deliveries do
      Task.Supervisor.start_child(Hub.WebhookTaskSupervisor, fn ->
        execute_delivery(webhook, delivery)
      end)
    end

    {:noreply, state}
  end

  def handle_cast(:process_retries, state) do
    retries = Webhooks.pending_retries()

    for delivery <- retries do
      webhook = delivery.webhook

      if webhook && webhook.active do
        Task.Supervisor.start_child(Hub.WebhookTaskSupervisor, fn ->
          execute_delivery(webhook, delivery)
        end)
      else
        # Webhook disabled or deleted — mark as failed
        Webhooks.update_delivery(delivery, %{status: "failed", next_retry_at: nil})
      end
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:retry_tick, state) do
    process_retries()
    Process.send_after(self(), :retry_tick, 15_000)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Delivery Execution ─────────────────────────────────────

  defp execute_delivery(webhook, delivery) do
    config = get_config()
    payload_json = Jason.encode!(delivery.payload)
    signature = Webhooks.sign_payload(payload_json, webhook.secret)
    timestamp = System.system_time(:second)

    headers = [
      {"content-type", "application/json"},
      {"x-ringforge-signature", "sha256=#{signature}"},
      {"x-ringforge-event", delivery.event_type},
      {"x-ringforge-delivery", delivery.id},
      {"x-ringforge-timestamp", to_string(timestamp)}
    ]

    timeout = config.timeout_ms

    case :hackney.request(:post, webhook.url, headers, payload_json, [
           recv_timeout: timeout,
           connect_timeout: timeout,
           follow_redirect: false
         ]) do
      {:ok, status, _resp_headers, client_ref} ->
        body =
          case :hackney.body(client_ref) do
            {:ok, b} -> b
            _ -> ""
          end

        if status >= 200 and status < 300 do
          Webhooks.update_delivery(delivery, %{
            status: "success",
            response_status: status,
            response_body: body,
            next_retry_at: nil
          })

          # Cleanup old logs
          Webhooks.cleanup_deliveries(webhook.id)
        else
          handle_failure(webhook, delivery, config, status, body)
        end

      {:error, reason} ->
        Logger.warning(
          "[WebhookDispatcher] HTTP error for webhook #{webhook.id}: #{inspect(reason)}"
        )

        handle_failure(webhook, delivery, config, nil, inspect(reason))
    end
  rescue
    e ->
      Logger.error(
        "[WebhookDispatcher] Exception delivering webhook #{webhook.id}: #{inspect(e)}"
      )

      handle_failure(webhook, delivery, get_config(), nil, inspect(e))
  end

  defp handle_failure(webhook, delivery, config, status, body) do
    attempt = delivery.attempt
    max_retries = config.max_retries
    retry_delays = config.retry_delays

    if attempt < max_retries do
      delay_ms = Enum.at(retry_delays, attempt - 1, List.last(retry_delays))
      next_retry = DateTime.utc_now() |> DateTime.add(delay_ms, :millisecond) |> DateTime.truncate(:second)

      # Update current delivery as failed, create next attempt
      Webhooks.update_delivery(delivery, %{
        status: "failed",
        response_status: status,
        response_body: body || "",
        next_retry_at: nil
      })

      # Create a new delivery record for the retry
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      %Hub.Schemas.WebhookDelivery{}
      |> Hub.Schemas.WebhookDelivery.changeset(%{
        webhook_id: webhook.id,
        event_type: delivery.event_type,
        payload: delivery.payload,
        attempt: attempt + 1,
        delivered_at: now,
        next_retry_at: next_retry,
        status: "pending"
      })
      |> Hub.Repo.insert()

      Logger.info(
        "[WebhookDispatcher] Webhook #{webhook.id} attempt #{attempt} failed, retry #{attempt + 1} scheduled at #{next_retry}"
      )
    else
      Webhooks.update_delivery(delivery, %{
        status: "failed",
        response_status: status,
        response_body: body || "",
        next_retry_at: nil
      })

      Logger.warning(
        "[WebhookDispatcher] Webhook #{webhook.id} delivery #{delivery.id} failed after #{attempt} attempts"
      )

      # Cleanup old logs
      Webhooks.cleanup_deliveries(webhook.id)
    end
  end

  defp get_config do
    app_config = Application.get_env(:hub, Hub.WebhookDispatcher, [])

    %{
      max_retries: Keyword.get(app_config, :max_retries, @default_config.max_retries),
      timeout_ms: Keyword.get(app_config, :timeout_ms, @default_config.timeout_ms),
      retry_delays: Keyword.get(app_config, :retry_delays, @default_config.retry_delays)
    }
  end
end
