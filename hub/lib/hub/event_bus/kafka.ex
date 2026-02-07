defmodule Hub.EventBus.Kafka do
  @moduledoc """
  Kafka-backed EventBus implementation using the `brod` client.

  Produces and consumes events on Kafka topics named after the
  convention `ringforge.{fleet_id}.{type}` (activity, memory,
  direct, tasks, etc.).

  ## Configuration

      config :hub, event_bus: Hub.EventBus.Kafka

      config :hub, Hub.EventBus.Kafka,
        brokers: [{"localhost", 9094}],
        client_id: :ringforge_kafka

  ## Topic Layout

  | Pattern                               | Partitions | Retention  | Purpose           |
  |---------------------------------------|-----------|------------|-------------------|
  | `ringforge.{fleet}.activity`          | 6         | Per plan   | Activity events   |
  | `ringforge.{fleet}.memory`            | 3         | Compacted  | Memory changelog  |
  | `ringforge.{fleet}.tasks`             | 6         | 7 d        | Task lifecycle    |
  | `ringforge.{fleet}.direct`            | 3         | 7 d        | Direct messages   |
  | `ringforge.system.telemetry`          | 3         | 7 d        | Platform metrics  |

  ## Partition Keys

  - Activity/tasks/direct → `agent_id` (ordered per-agent replay)
  - Memory → `key` (compacted per-key)
  - Telemetry → round-robin

  ## Tenant Isolation

  Each fleet gets its own topics. Fleet A's consumers never read
  fleet B's topics.
  """

  use GenServer
  require Logger

  @behaviour Hub.EventBus

  @default_brokers [{"localhost", 9094}]
  @default_client_id :ringforge_kafka

  # Topic configs: {partition_count, cleanup_policy, retention_ms}
  @topic_configs %{
    "activity" => {6, "delete", 7 * 86_400_000},
    "memory"   => {3, "compact", -1},
    "tasks"    => {6, "delete", 7 * 86_400_000},
    "direct"   => {3, "delete", 7 * 86_400_000},
    "telemetry" => {3, "delete", 7 * 86_400_000}
  }

  # Backpressure: max queued produce requests before shedding
  @max_queue_size 5_000
  @produce_timeout 10_000
  @replay_timeout 15_000

  # ── Public API (behaviour callbacks) ──────────────────────────

  @impl Hub.EventBus
  def publish(topic, event) do
    GenServer.call(__MODULE__, {:publish, topic, event}, @produce_timeout)
  catch
    :exit, {:timeout, _} ->
      Logger.warning("[EventBus.Kafka] Publish timeout on #{topic}")
      {:error, :timeout}

    :exit, reason ->
      Logger.warning("[EventBus.Kafka] Publish exit: #{inspect(reason)}")
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
      Logger.warning("[EventBus.Kafka] Replay timeout on #{topic}")
      {:error, :timeout}

    :exit, reason ->
      Logger.warning("[EventBus.Kafka] Replay exit: #{inspect(reason)}")
      {:error, :unavailable}
  end

  # ── GenServer ─────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    config = Application.get_env(:hub, __MODULE__, [])
    brokers = Keyword.get(config, :brokers, @default_brokers)
    client_id = Keyword.get(config, :client_id, @default_client_id)

    state = %{
      client_id: client_id,
      brokers: brokers,
      connected: false,
      known_topics: MapSet.new(),
      subscribers: %{},
      queue_size: 0
    }

    # Start brod client — non-blocking init; degraded mode on failure
    case start_brod_client(brokers, client_id) do
      :ok ->
        Logger.info("[EventBus.Kafka] brod client started → #{inspect(brokers)}")
        {:ok, %{state | connected: true}}

      {:error, reason} ->
        Logger.warning(
          "[EventBus.Kafka] Failed to start brod client: #{inspect(reason)} — " <>
            "will retry on first publish"
        )

        schedule_reconnect()
        {:ok, state}
    end
  end

  # ── Publish ───────────────────────────────────────────────────

  @impl GenServer
  def handle_call({:publish, topic, _event}, _from, %{connected: false} = state) do
    Logger.warning("[EventBus.Kafka] Not connected — dropping publish to #{topic}")
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:publish, _topic, _event}, _from, %{queue_size: qs} = state)
      when qs >= @max_queue_size do
    Logger.warning("[EventBus.Kafka] Backpressure: queue full (#{qs}), shedding event")
    {:reply, {:error, :backpressure}, state}
  end

  def handle_call({:publish, topic, event}, _from, state) do
    state = maybe_ensure_topic(state, topic)

    partition_key = extract_partition_key(topic, event)
    value = Jason.encode!(event)

    state = %{state | queue_size: state.queue_size + 1}

    result =
      case :brod.produce_sync(state.client_id, topic, :hash, partition_key, value) do
        :ok ->
          notify_subscribers(state, topic, event)
          :ok

        {:error, :unknown_topic_or_partition} ->
          handle_unknown_topic(state, topic, partition_key, value, event)

        {:error, reason} ->
          Logger.error("[EventBus.Kafka] Publish failed on #{topic}: #{inspect(reason)}")
          {:error, reason}
      end

    state = %{state | queue_size: max(0, state.queue_size - 1)}
    {:reply, result, state}
  end

  # ── Subscribe ─────────────────────────────────────────────────

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

  # ── Replay ────────────────────────────────────────────────────

  def handle_call({:replay, _topic, _opts}, _from, %{connected: false} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:replay, topic, opts}, _from, %{client_id: client_id} = state) do
    limit = Keyword.get(opts, :limit, 100)
    kinds = Keyword.get(opts, :kinds, nil)
    from_ts = Keyword.get(opts, :from_timestamp, nil)

    result = replay_all_partitions(client_id, topic, limit, from_ts)

    case result do
      {:ok, events} ->
        filtered =
          events
          |> maybe_filter_kinds(kinds)
          |> Enum.take(-limit)

        {:reply, {:ok, filtered}, state}

      {:error, :unknown_topic_or_partition} ->
        # Topic doesn't exist yet — not an error, just empty
        {:reply, {:ok, []}, state}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  # ── Reconnection ──────────────────────────────────────────────

  @impl GenServer
  def handle_info(:reconnect, %{connected: true} = state) do
    {:noreply, state}
  end

  def handle_info(:reconnect, %{brokers: brokers, client_id: client_id} = state) do
    case start_brod_client(brokers, client_id) do
      :ok ->
        Logger.info("[EventBus.Kafka] Reconnected to Kafka")
        {:noreply, %{state | connected: true}}

      {:error, _reason} ->
        schedule_reconnect()
        {:noreply, state}
    end
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
    Logger.debug("[EventBus.Kafka] Unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # ── Private: Brod Client ──────────────────────────────────────

  defp start_brod_client(brokers, client_id) do
    client_config = [
      reconnect_cool_down_seconds: 5,
      auto_start_producers: true,
      default_producer_config: [
        required_acks: :leader,
        max_retries: 3,
        retry_backoff_ms: 500
      ]
    ]

    case :brod.start_client(brokers, client_id, client_config) do
      :ok -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp schedule_reconnect do
    Process.send_after(self(), :reconnect, 10_000)
  end

  # ── Private: Topic Management ─────────────────────────────────

  defp maybe_ensure_topic(state, topic) do
    if MapSet.member?(state.known_topics, topic) do
      state
    else
      case ensure_topic(state, topic) do
        :ok ->
          %{state | known_topics: MapSet.put(state.known_topics, topic)}

        {:error, _} ->
          # Still add to known_topics to avoid hammering create on every publish.
          # Kafka auto.create.topics.enable may handle it.
          %{state | known_topics: MapSet.put(state.known_topics, topic)}
      end
    end
  end

  defp ensure_topic(%{brokers: brokers}, topic) do
    {partitions, cleanup, retention_ms} = topic_config_for(topic)

    config_entries =
      [{"cleanup.policy", cleanup}] ++
        if retention_ms > 0 do
          [{"retention.ms", Integer.to_string(retention_ms)}]
        else
          []
        end

    topic_config = %{
      topic: topic,
      num_partitions: partitions,
      replication_factor: 1,
      replica_assignment: [],
      config_entries: Enum.map(config_entries, fn {k, v} -> %{config_key: k, config_value: v} end)
    }

    case :brod.create_topics(brokers, [topic_config], %{timeout: 10_000}) do
      :ok ->
        Logger.info("[EventBus.Kafka] Created topic: #{topic} (#{partitions}p, #{cleanup})")
        # Allow metadata propagation
        Process.sleep(500)
        :ok

      {:error, :topic_already_exists} ->
        :ok

      {:error, reason} ->
        Logger.warning("[EventBus.Kafka] Could not create topic #{topic}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp topic_config_for(topic) do
    # Extract the type suffix from "ringforge.{fleet}.{type}"
    type =
      topic
      |> String.split(".")
      |> List.last()

    Map.get(@topic_configs, type, {3, "delete", 7 * 86_400_000})
  end

  # ── Private: Partition Keys ───────────────────────────────────

  defp extract_partition_key(topic, event) do
    type =
      topic
      |> String.split(".")
      |> List.last()

    case type do
      "memory" ->
        # Partition by key for log compaction
        extract_memory_key(event)

      "telemetry" ->
        # Round-robin (empty key → brod distributes evenly)
        ""

      _ ->
        # activity, tasks, direct → partition by agent_id
        extract_agent_id(event)
    end
  end

  defp extract_agent_id(event) do
    case event do
      %{"from" => %{"agent_id" => id}} when is_binary(id) -> id
      %{from: %{agent_id: id}} when is_binary(id) -> id
      %{"agent_id" => id} when is_binary(id) -> id
      %{agent_id: id} when is_binary(id) -> id
      %{"from" => id} when is_binary(id) -> id
      _ -> "default"
    end
  end

  defp extract_memory_key(event) do
    case event do
      %{"key" => k} when is_binary(k) -> k
      %{key: k} when is_binary(k) -> k
      _ -> "default"
    end
  end

  # ── Private: Publish Helpers ──────────────────────────────────

  defp handle_unknown_topic(state, topic, partition_key, value, event) do
    Logger.info("[EventBus.Kafka] Topic #{topic} not found, auto-creating...")

    case ensure_topic(state, topic) do
      :ok ->
        case :brod.produce_sync(state.client_id, topic, :hash, partition_key, value) do
          :ok ->
            notify_subscribers(state, topic, event)
            :ok

          {:error, reason} ->
            Logger.error("[EventBus.Kafka] Retry publish failed on #{topic}: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

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
          Logger.warning("[EventBus.Kafka] Subscriber callback error: #{inspect(e)}")
      end
    end)
  end

  # ── Private: Replay ───────────────────────────────────────────

  defp replay_all_partitions(client_id, topic, limit, from_ts) do
    # Get partition count for this topic
    case get_partition_count(client_id, topic) do
      {:ok, count} ->
        # Fetch from all partitions in parallel
        tasks =
          for partition <- 0..(count - 1) do
            Task.async(fn ->
              replay_partition(client_id, topic, partition, limit, from_ts)
            end)
          end

        results = Task.await_many(tasks, @replay_timeout - 1_000)

        events =
          results
          |> Enum.flat_map(fn
            {:ok, msgs} -> msgs
            {:error, _} -> []
          end)
          |> Enum.sort_by(fn event ->
            # Sort by timestamp if present, otherwise by insertion order
            case event do
              %{"timestamp" => ts} -> ts
              %{"ts" => ts} -> ts
              _ -> 0
            end
          end)

        {:ok, events}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e ->
      Logger.error("[EventBus.Kafka] Replay error: #{Exception.message(e)}")
      {:error, :replay_failed}
  end

  defp get_partition_count(client_id, topic) do
    case :brod.get_partitions_count(client_id, topic) do
      {:ok, count} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end

  defp replay_partition(client_id, topic, partition, limit, from_ts) do
    offset = resolve_partition_offset(client_id, topic, partition, limit, from_ts)

    case fetch_partition_messages(client_id, topic, partition, offset, limit) do
      {:ok, messages} -> {:ok, messages}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_partition_offset(client_id, topic, partition, limit, nil) do
    # No timestamp — get last N messages
    case :brod.resolve_offset(client_id, topic, partition, :latest) do
      {:ok, latest} -> max(0, latest - limit)
      {:error, _} -> 0
    end
  end

  defp resolve_partition_offset(client_id, topic, partition, _limit, from_ts)
       when is_integer(from_ts) do
    # Resolve offset from timestamp
    case :brod.resolve_offset(client_id, topic, partition, from_ts) do
      {:ok, offset} -> offset
      {:error, _} -> 0
    end
  end

  defp fetch_partition_messages(client_id, topic, partition, offset, limit) do
    # Fetch in chunks up to limit
    max_bytes = min(limit * 4096, 4_194_304)

    case :brod.fetch(client_id, topic, partition, offset, %{max_bytes: max_bytes}) do
      {:ok, {_hw, messages}} ->
        events =
          messages
          |> Enum.take(limit)
          |> Enum.flat_map(fn msg ->
            value = extract_message_value(msg)

            case Jason.decode(value) do
              {:ok, decoded} -> [decoded]
              _ -> []
            end
          end)

        {:ok, events}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_message_value(msg) when is_tuple(msg) do
    # brod message record: {:kafka_message, offset, key, value, ...}
    # The value is typically at index 4 (0-based: element 5)
    case msg do
      {:kafka_message, _offset, _key, value, _ts_type, _ts, _headers} -> value
      _ -> elem(msg, 3)
    end
  rescue
    _ -> ""
  end

  # ── Private: Filters ──────────────────────────────────────────

  defp maybe_filter_kinds(events, nil), do: events
  defp maybe_filter_kinds(events, []), do: events

  defp maybe_filter_kinds(events, kinds) when is_list(kinds) do
    Enum.filter(events, fn event ->
      Map.get(event, "kind") in kinds || Map.get(event, :kind) in kinds
    end)
  end
end
