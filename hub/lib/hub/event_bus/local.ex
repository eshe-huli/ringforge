defmodule Hub.EventBus.Local do
  @moduledoc """
  ETS-backed EventBus implementation for development and testing.

  Stores events in an ETS table keyed by topic. Each topic is capped
  at `@max_events_per_topic` (10,000) entries — oldest events are
  evicted when the cap is reached.

  This backend requires no external services and is the default
  fallback when Kafka is unavailable.

  ## Storage Format

  ETS entries: `{topic, timestamp_microseconds, event_map}`

  ## Usage

  Set in config:

      config :hub, event_bus: Hub.EventBus.Local
  """

  use GenServer
  require Logger

  @behaviour Hub.EventBus

  @table :hub_event_bus_local
  @max_events_per_topic 10_000

  # ── Public API (behaviour callbacks) ──────────────────────────

  @impl Hub.EventBus
  def publish(topic, event) do
    GenServer.call(__MODULE__, {:publish, topic, event})
  end

  @impl Hub.EventBus
  def subscribe(_topic, _opts \\ []) do
    # Local backend doesn't need real subscriptions — events are
    # available via replay. This is a no-op that satisfies the contract.
    :ok
  end

  @impl Hub.EventBus
  def replay(topic, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    kinds = Keyword.get(opts, :kinds, nil)

    events =
      @table
      |> :ets.match_object({topic, :_, :_})
      |> Enum.sort_by(fn {_t, {ts, seq}, _e} -> {ts, seq} end, :asc)
      |> Enum.map(fn {_t, _key, event} -> event end)
      |> maybe_filter_kinds(kinds)
      |> Enum.take(-limit)

    {:ok, events}
  end

  # ── GenServer ─────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :bag, :public, read_concurrency: true])
    Logger.info("[EventBus.Local] ETS backend started (table: #{inspect(table)})")
    {:ok, %{table: table, counter: 0}}
  end

  @impl GenServer
  def handle_call({:publish, topic, event}, _from, state) do
    seq = state.counter + 1
    ts = System.system_time(:microsecond)
    :ets.insert(@table, {topic, {ts, seq}, event})

    # Evict oldest if over cap
    evict_if_needed(topic)

    {:reply, :ok, %{state | counter: seq}}
  end

  # ── Private ───────────────────────────────────────────────────

  defp evict_if_needed(topic) do
    entries = :ets.match_object(@table, {topic, :_, :_})
    count = length(entries)

    if count > @max_events_per_topic do
      to_remove = count - @max_events_per_topic

      entries
      |> Enum.sort_by(fn {_t, {ts, seq}, _e} -> {ts, seq} end, :asc)
      |> Enum.take(to_remove)
      |> Enum.each(fn entry -> :ets.delete_object(@table, entry) end)
    end
  end

  defp maybe_filter_kinds(events, nil), do: events
  defp maybe_filter_kinds(events, []), do: events

  defp maybe_filter_kinds(events, kinds) when is_list(kinds) do
    Enum.filter(events, fn event ->
      Map.get(event, "kind") in kinds || Map.get(event, :kind) in kinds
    end)
  end
end
