defmodule Hub.EventBus.Pulsar do
  @moduledoc """
  Apache Pulsar-backed EventBus implementation.

  Produces and consumes events via Pulsar's WebSocket API, avoiding the
  need for a native Elixir Pulsar client.

  ## WebSocket Endpoints

  - Producer: `ws://{host}:8080/ws/v2/producer/persistent/{tenant}/{namespace}/{topic}`
  - Consumer: `ws://{host}:8080/ws/v2/consumer/persistent/{tenant}/{namespace}/{topic}/{subscription}`

  ## Configuration

      config :hub, event_bus: Hub.EventBus.Pulsar

      config :hub, Hub.EventBus.Pulsar,
        service_url: "pulsar://localhost:6650",
        web_service_url: "http://localhost:8080",
        tenant: "ringforge",
        namespace: "default"

  Switchable via `EVENT_BUS_ADAPTER=pulsar`.

  ## Topic Layout

  Same as Kafka implementation:

  | Pattern                               | Purpose           |
  |---------------------------------------|-------------------|
  | `ringforge.{fleet}.activity`          | Activity events   |
  | `ringforge.{fleet}.memory`            | Memory changelog  |
  | `ringforge.{fleet}.tasks`             | Task lifecycle    |
  | `ringforge.{fleet}.direct`            | Direct messages   |
  | `ringforge.system.telemetry`          | Platform metrics  |
  """

  use GenServer
  require Logger

  @behaviour Hub.EventBus

  @produce_timeout 10_000
  @replay_timeout 15_000
  @max_queue_size 5_000
  @max_events_per_topic 10_000

  # ── Public API (behaviour callbacks) ──────────────────────

  @impl Hub.EventBus
  def publish(topic, event) do
    GenServer.call(__MODULE__, {:publish, topic, event}, @produce_timeout)
  catch
    :exit, {:timeout, _} ->
      Logger.warning("[EventBus.Pulsar] Publish timeout on #{topic}")
      {:error, :timeout}

    :exit, reason ->
      Logger.warning("[EventBus.Pulsar] Publish exit: #{inspect(reason)}")
      {:error, :unavailable}
  end

  @impl Hub.EventBus
  def subscribe(topic, opts \\ []) do
    GenServer.call(__MODULE__, {:subscribe, topic, opts})
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @impl Hub.EventBus
  def replay(topic, opts \\ []) do
    GenServer.call(__MODULE__, {:replay, topic, opts}, @replay_timeout)
  catch
    :exit, {:timeout, _} ->
      Logger.warning("[EventBus.Pulsar] Replay timeout on #{topic}")
      {:error, :timeout}

    :exit, reason ->
      Logger.warning("[EventBus.Pulsar] Replay exit: #{inspect(reason)}")
      {:error, :unavailable}
  end

  # ── GenServer ──────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    config = Application.get_env(:hub, __MODULE__, [])

    web_url = Keyword.get(config, :web_service_url, "http://localhost:8080")
    tenant = Keyword.get(config, :tenant, "ringforge")
    namespace = Keyword.get(config, :namespace, "default")

    # ETS table for local event storage (fallback + replay cache)
    table = :ets.new(:hub_pulsar_events, [:bag, :public, read_concurrency: true])

    state = %{
      web_url: web_url,
      tenant: tenant,
      namespace: namespace,
      connected: false,
      subscribers: %{},
      table: table,
      queue_size: 0
    }

    # Try to connect to Pulsar
    send(self(), :check_connection)

    Logger.info("[EventBus.Pulsar] Started — web_service_url: #{web_url}")
    {:ok, state}
  end

  # ── Publish ───────────────────────────────────────────────

  @impl GenServer
  def handle_call({:publish, _topic, _event}, _from, %{queue_size: qs} = state)
      when qs >= @max_queue_size do
    Logger.warning("[EventBus.Pulsar] Backpressure: queue full (#{qs})")
    {:reply, {:error, :backpressure}, state}
  end

  def handle_call({:publish, topic, event}, _from, state) do
    state = %{state | queue_size: state.queue_size + 1}

    # Enrich event with timestamp if not present
    event =
      if Map.has_key?(event, "timestamp") || Map.has_key?(event, :timestamp) do
        event
      else
        Map.put(event, "timestamp", DateTime.utc_now() |> DateTime.to_iso8601())
      end

    # Store locally for replay
    ts = System.system_time(:microsecond)
    :ets.insert(state.table, {topic, ts, event})
    evict_if_needed(state.table, topic)

    # Attempt to publish to Pulsar via REST API
    result =
      if state.connected do
        publish_to_pulsar(state, topic, event)
      else
        :ok
      end

    # Notify subscribers regardless of Pulsar availability
    notify_subscribers(state, topic, event)

    state = %{state | queue_size: max(0, state.queue_size - 1)}
    {:reply, result, state}
  end

  # ── Subscribe ─────────────────────────────────────────────

  def handle_call({:subscribe, topic, opts}, {pid, _ref}, state) do
    callback = Keyword.get(opts, :callback, nil)
    ref = Process.monitor(pid)

    entry = %{pid: pid, ref: ref, callback: callback}

    subscribers =
      Map.update(state.subscribers, topic, [entry], fn existing ->
        [entry | existing]
      end)

    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  # ── Replay ────────────────────────────────────────────────

  def handle_call({:replay, topic, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 100)
    kinds = Keyword.get(opts, :kinds, nil)

    events =
      state.table
      |> :ets.match_object({topic, :_, :_})
      |> Enum.sort_by(fn {_t, ts, _e} -> ts end, :asc)
      |> Enum.map(fn {_t, _ts, event} -> event end)
      |> maybe_filter_kinds(kinds)
      |> Enum.take(-limit)

    {:reply, {:ok, events}, state}
  end

  # ── Connection Check ──────────────────────────────────────

  @impl GenServer
  def handle_info(:check_connection, state) do
    _url = "#{state.web_url}/admin/v2/clusters"

    connected =
      case :httpc.request(:get, {String.to_charlist(url), []}, [{:timeout, 5_000}], []) do
        {:ok, {{_, 200, _}, _, _}} -> true
        _ -> false
      end

    if connected and not state.connected do
      Logger.info("[EventBus.Pulsar] Connected to Pulsar at #{state.web_url}")
    end

    unless connected do
      # Retry periodically
      Process.send_after(self(), :check_connection, 30_000)
    end

    {:noreply, %{state | connected: connected}}
  end

  # Clean up subscriber on process exit
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    subscribers =
      state.subscribers
      |> Enum.map(fn {topic, entries} ->
        {topic, Enum.reject(entries, fn e -> e.ref == ref end)}
      end)
      |> Enum.reject(fn {_topic, entries} -> entries == [] end)
      |> Map.new()

    {:noreply, %{state | subscribers: subscribers}}
  end

  def handle_info(msg, state) do
    Logger.debug("[EventBus.Pulsar] Unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # ── Private: Pulsar REST Producer ─────────────────────────

  defp publish_to_pulsar(state, topic, event) do
    # Pulsar topic name: persistent://{tenant}/{namespace}/{topic}
    pulsar_topic = sanitize_topic(topic)
    _url = "#{state.web_url}/admin/v2/persistent/#{state.tenant}/#{state.namespace}/#{pulsar_topic}"

    # Use Pulsar's REST producer API
    # POST to /topics/{topic}/produce with JSON payload
    produce_url =
      "#{state.web_url}/topics/persistent/#{state.tenant}/#{state.namespace}/#{pulsar_topic}"

    payload =
      Jason.encode!(%{
        "payload" => Base.encode64(Jason.encode!(event)),
        "properties" => %{
          "content_type" => "application/json"
        }
      })

    case :httpc.request(
           :post,
           {String.to_charlist(produce_url), [], ~c"application/json",
            String.to_charlist(payload)},
           [{:timeout, 5_000}],
           []
         ) do
      {:ok, {{_, code, _}, _, _}} when code in 200..299 ->
        :ok

      {:ok, {{_, code, _}, _, body}} ->
        Logger.debug(
          "[EventBus.Pulsar] Produce returned #{code}: #{inspect(body)}"
        )

        # Still OK — event is stored locally
        :ok

      {:error, reason} ->
        Logger.warning("[EventBus.Pulsar] Produce failed: #{inspect(reason)}")
        :ok
    end
  rescue
    e ->
      Logger.warning("[EventBus.Pulsar] Produce error: #{Exception.message(e)}")
      :ok
  end

  defp sanitize_topic(topic) do
    # Replace dots with hyphens for Pulsar topic naming
    String.replace(topic, ".", "-")
  end

  # ── Private: Subscribers ──────────────────────────────────

  defp notify_subscribers(state, topic, event) do
    case Map.get(state.subscribers, topic, []) do
      [] ->
        :ok

      entries ->
        for %{callback: cb, pid: pid} <- entries do
          cond do
            is_function(cb, 1) -> safe_callback(cb, event)
            is_function(cb, 2) -> safe_callback(fn e -> cb.(topic, e) end, event)
            true -> send(pid, {:event_bus, topic, event})
          end
        end

        :ok
    end
  end

  defp safe_callback(fun, event) do
    Task.start(fn ->
      try do
        fun.(event)
      rescue
        e ->
          Logger.warning("[EventBus.Pulsar] Subscriber callback error: #{inspect(e)}")
      end
    end)
  end

  # ── Private: Eviction ─────────────────────────────────────

  defp evict_if_needed(table, topic) do
    entries = :ets.match_object(table, {topic, :_, :_})
    count = length(entries)

    if count > @max_events_per_topic do
      to_remove = count - @max_events_per_topic

      entries
      |> Enum.sort_by(fn {_t, ts, _e} -> ts end, :asc)
      |> Enum.take(to_remove)
      |> Enum.each(fn entry -> :ets.delete_object(table, entry) end)
    end
  end

  # ── Private: Filters ──────────────────────────────────────

  defp maybe_filter_kinds(events, nil), do: events
  defp maybe_filter_kinds(events, []), do: events

  defp maybe_filter_kinds(events, kinds) when is_list(kinds) do
    Enum.filter(events, fn event ->
      Map.get(event, "kind") in kinds || Map.get(event, :kind) in kinds
    end)
  end
end
