defmodule Hub.Alerts do
  @moduledoc """
  Alert rules engine for Ringforge observability.

  Periodically checks alert conditions and broadcasts triggered alerts
  to the dashboard via PubSub. Optionally triggers webhook notifications.

  ## Alert Rules

  - Agent disconnect spike (>50% of fleet disconnects in 1 min)
  - Auth failure spike (>50 failures/min)
  - Task timeout rate >10%
  - Quota near limit (>80%)
  - Webhook delivery failure rate >50%
  """
  use GenServer

  require Logger

  @check_interval_ms 30_000  # Check every 30 seconds
  @window_ms 60_000          # 1-minute sliding window

  # ── Public API ─────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get list of currently active alerts."
  def active_alerts do
    GenServer.call(__MODULE__, :active_alerts)
  end

  @doc "Get alert history (last 100 alerts)."
  def alert_history do
    GenServer.call(__MODULE__, :alert_history)
  end

  # ── GenServer Callbacks ────────────────────────────────────

  @impl true
  def init(_opts) do
    # Attach telemetry handlers to track events in sliding windows
    attach_handlers()

    schedule_check()

    state = %{
      # Sliding window event counters: %{event_type => [timestamps]}
      windows: %{
        channel_join: [],
        channel_leave: [],
        auth_failure: [],
        auth_success: [],
        task_completed: [],
        task_failed: [],
        webhook_success: [],
        webhook_failure: []
      },
      active_alerts: [],
      history: []
    }

    Logger.info("[Hub.Alerts] Alert checker started (interval: #{@check_interval_ms}ms)")
    {:ok, state}
  end

  @impl true
  def handle_call(:active_alerts, _from, state) do
    {:reply, state.active_alerts, state}
  end

  @impl true
  def handle_call(:alert_history, _from, state) do
    {:reply, Enum.take(state.history, 100), state}
  end

  @impl true
  def handle_info(:check_alerts, state) do
    now = System.monotonic_time(:millisecond)

    # Prune old entries from windows
    windows = Map.new(state.windows, fn {k, timestamps} ->
      {k, Enum.filter(timestamps, &(&1 > now - @window_ms))}
    end)

    # Run alert checks
    alerts = check_all_rules(windows)

    # Find new alerts (not already active)
    active_ids = MapSet.new(state.active_alerts, & &1.id)
    new_alerts = Enum.reject(alerts, &MapSet.member?(active_ids, &1.id))

    # Broadcast new alerts
    Enum.each(new_alerts, fn alert ->
      broadcast_alert(alert)
      Logger.warning("[Hub.Alerts] Alert triggered: #{alert.id} — #{alert.message}")
    end)

    # Update history
    history = new_alerts ++ state.history
    history = Enum.take(history, 100)

    schedule_check()
    {:noreply, %{state | windows: windows, active_alerts: alerts, history: history}}
  end

  # Telemetry event tracking
  @impl true
  def handle_info({:telemetry_event, type}, state) do
    now = System.monotonic_time(:millisecond)
    windows = Map.update(state.windows, type, [now], &[now | &1])
    {:noreply, %{state | windows: windows}}
  end

  # ── Alert Rules ────────────────────────────────────────────

  defp check_all_rules(windows) do
    []
    |> check_disconnect_spike(windows)
    |> check_auth_failure_spike(windows)
    |> check_task_timeout_rate(windows)
    |> check_quota_limits()
    |> check_webhook_failure_rate(windows)
  end

  defp check_disconnect_spike(alerts, windows) do
    leaves = length(windows[:channel_leave] || [])
    joins = length(windows[:channel_join] || [])

    # If we had agents connected and more than 50% disconnected in the window
    if leaves > 3 and joins > 0 and leaves / max(joins + leaves, 1) > 0.5 do
      [%{
        id: "disconnect_spike",
        severity: :critical,
        message: "Agent disconnect spike: #{leaves} disconnects in the last minute",
        value: leaves,
        threshold: "50% of fleet",
        triggered_at: DateTime.utc_now() |> DateTime.to_iso8601()
      } | alerts]
    else
      alerts
    end
  end

  defp check_auth_failure_spike(alerts, windows) do
    failures = length(windows[:auth_failure] || [])

    if failures > 50 do
      [%{
        id: "auth_failure_spike",
        severity: :warning,
        message: "Auth failure spike: #{failures} failures in the last minute",
        value: failures,
        threshold: 50,
        triggered_at: DateTime.utc_now() |> DateTime.to_iso8601()
      } | alerts]
    else
      alerts
    end
  end

  defp check_task_timeout_rate(alerts, windows) do
    completed = length(windows[:task_completed] || [])
    failed = length(windows[:task_failed] || [])
    total = completed + failed

    if total > 5 and failed / total > 0.1 do
      rate = Float.round(failed / total * 100, 1)
      [%{
        id: "task_failure_rate",
        severity: :warning,
        message: "Task failure rate: #{rate}% (#{failed}/#{total}) in the last minute",
        value: rate,
        threshold: 10.0,
        triggered_at: DateTime.utc_now() |> DateTime.to_iso8601()
      } | alerts]
    else
      alerts
    end
  end

  defp check_quota_limits(alerts) do
    # Check all tenants for quota warnings
    import Ecto.Query

    tenants = Hub.Repo.all(from(t in Hub.Auth.Tenant, select: {t.id, t.plan}))

    Enum.reduce(tenants, alerts, fn {tenant_id, _plan}, acc ->
      usage = Hub.Quota.get_usage(tenant_id)

      Enum.reduce(usage, acc, fn
        {resource, %{used: used, limit: limit}}, inner_acc
            when is_integer(limit) and limit > 0 and used / limit >= 0.8 ->
          pct = Float.round(used / limit * 100, 1)
          [%{
            id: "quota_#{resource}_#{tenant_id}",
            severity: if(pct >= 95, do: :critical, else: :warning),
            message: "Quota #{resource} at #{pct}% for tenant #{String.slice(tenant_id, 0..7)}",
            value: pct,
            threshold: 80.0,
            triggered_at: DateTime.utc_now() |> DateTime.to_iso8601()
          } | inner_acc]

        _, inner_acc -> inner_acc
      end)
    end)
  rescue
    _ -> alerts
  end

  defp check_webhook_failure_rate(alerts, windows) do
    successes = length(windows[:webhook_success] || [])
    failures = length(windows[:webhook_failure] || [])
    total = successes + failures

    if total > 5 and failures / total > 0.5 do
      rate = Float.round(failures / total * 100, 1)
      [%{
        id: "webhook_failure_rate",
        severity: :warning,
        message: "Webhook delivery failure rate: #{rate}% (#{failures}/#{total}) in the last minute",
        value: rate,
        threshold: 50.0,
        triggered_at: DateTime.utc_now() |> DateTime.to_iso8601()
      } | alerts]
    else
      alerts
    end
  end

  # ── Helpers ────────────────────────────────────────────────

  defp schedule_check do
    Process.send_after(self(), :check_alerts, @check_interval_ms)
  end

  defp broadcast_alert(alert) do
    Phoenix.PubSub.broadcast(Hub.PubSub, "hub:alerts", {:alert_triggered, alert})
  end

  defp attach_handlers do
    events = [
      {[:hub, :channel, :join], :channel_join},
      {[:hub, :channel, :leave], :channel_leave},
      {[:hub, :auth, :success], :auth_success},
      {[:hub, :auth, :failure], :auth_failure},
      {[:hub, :task, :completed], :task_completed},
      {[:hub, :task, :failed], :task_failed},
      {[:hub, :webhook, :delivered], :webhook_delivered}
    ]

    pid = self()

    Enum.each(events, fn {event, type} ->
      handler_id = "hub-alerts-#{Enum.join(Enum.map(event, &to_string/1), "-")}"

      :telemetry.attach(handler_id, event, fn _event, _measurements, metadata, _config ->
        # For webhook events, distinguish success/failure
        actual_type = case type do
          :webhook_delivered ->
            if Map.get(metadata, :status) in ["success", "200", "201"], do: :webhook_success, else: :webhook_failure
          other -> other
        end
        send(pid, {:telemetry_event, actual_type})
      end, nil)
    end)
  end
end
