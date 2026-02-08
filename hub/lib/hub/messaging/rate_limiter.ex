defmodule Hub.Messaging.RateLimiter do
  @moduledoc """
  Per-agent, per-tier message rate limiting.
  Uses ETS for fast lookups with periodic cleanup.

  Default limits by tier:
    Tier 0: unlimited
    Tier 1: unlimited
    Tier 2: 60/minute DM, 10/hour broadcast
    Tier 3: 20/minute DM, no broadcast (enforced by AccessControl)
    Tier 4: 5/minute DM, no broadcast
  """
  use GenServer

  require Logger

  @table :messaging_rate_limits
  @cleanup_interval_ms :timer.minutes(5)

  # Window durations in milliseconds
  @minute_ms :timer.minutes(1)
  @hour_ms :timer.hours(1)

  # ── Limits by tier ─────────────────────────────────────────

  @tier_limits %{
    0 => %{dm: :unlimited, broadcast: :unlimited},
    1 => %{dm: :unlimited, broadcast: :unlimited},
    2 => %{dm: {60, @minute_ms}, broadcast: {10, @hour_ms}},
    3 => %{dm: {20, @minute_ms}, broadcast: {3, @hour_ms}},
    4 => %{dm: {5, @minute_ms}, broadcast: :forbidden}
  }

  # ── Public API ─────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Check if an agent can perform the given action type under their tier's rate limit.

  Returns `:ok` if under the limit, or `{:limited, retry_after_ms}` if rate-limited.

  ## Parameters
  - `agent_id` — the agent's string ID (e.g., "ag_abc123")
  - `action_type` — `:dm` or `:broadcast`
  - `tier` — integer tier (0-4)
  """
  @spec check_rate(String.t(), :dm | :broadcast, non_neg_integer()) ::
          :ok | {:limited, non_neg_integer()}
  def check_rate(agent_id, action_type, tier) do
    limit = get_limit(tier, action_type)

    case limit do
      :unlimited ->
        :ok

      :forbidden ->
        {:limited, 0}

      {max_count, window_ms} ->
        now = System.monotonic_time(:millisecond)
        key = {agent_id, action_type}
        window_start = now - window_ms

        # Count events in the current window
        events = get_events(key)
        active_events = Enum.filter(events, fn ts -> ts > window_start end)
        count = length(active_events)

        if count < max_count do
          :ok
        else
          # Find when the oldest event in the window expires
          oldest = Enum.min(active_events)
          retry_after = oldest + window_ms - now
          {:limited, max(retry_after, 0)}
        end
    end
  end

  @doc """
  Record that an agent performed an action (after access check + rate check passed).

  Call this AFTER successfully routing a message.
  """
  @spec record(String.t(), :dm | :broadcast) :: :ok
  def record(agent_id, action_type) do
    key = {agent_id, action_type}
    now = System.monotonic_time(:millisecond)

    # Append the timestamp to the event list
    events = get_events(key)
    :ets.insert(@table, {key, [now | events]})
    :ok
  end

  @doc """
  Returns the configured limits for a tier.

  Returns a map like `%{dm: {count, window_ms}, broadcast: {count, window_ms}}`
  where values can be `:unlimited` or `:forbidden`.
  """
  @spec get_limits(non_neg_integer()) :: map()
  def get_limits(tier) do
    Map.get(@tier_limits, tier, @tier_limits[4])
  end

  # ── GenServer Callbacks ────────────────────────────────────

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    schedule_cleanup()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_expired()
    schedule_cleanup()
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("[RateLimiter] Unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # ── Private Helpers ────────────────────────────────────────

  defp get_events(key) do
    case :ets.lookup(@table, key) do
      [{^key, events}] -> events
      [] -> []
    end
  end

  defp get_limit(tier, action_type) do
    limits = Map.get(@tier_limits, tier, @tier_limits[4])
    Map.get(limits, action_type, :forbidden)
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end

  defp cleanup_expired do
    now = System.monotonic_time(:millisecond)
    # Keep events from the last hour (longest window)
    cutoff = now - @hour_ms

    :ets.foldl(
      fn {key, events}, _acc ->
        pruned = Enum.filter(events, fn ts -> ts > cutoff end)

        if pruned == [] do
          :ets.delete(@table, key)
        else
          :ets.insert(@table, {key, pruned})
        end

        :ok
      end,
      :ok,
      @table
    )
  rescue
    _ -> :ok
  end
end
