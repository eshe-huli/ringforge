defmodule Hub.EventBus.Kafka do
  @moduledoc """
  Kafka-backed EventBus implementation using the `brod` client.

  Connects to a Kafka cluster and produces/consumes events on
  topics named `ringforge.{fleet_id}.activity`.

  ## Configuration

      config :hub, event_bus: Hub.EventBus.Kafka

      config :hub, Hub.EventBus.Kafka,
        brokers: [{"localhost", 9094}],
        client_id: :ringforge_kafka

  ## Topic Auto-Creation

  Topics are auto-created by Kafka if `auto.create.topics.enable=true`
  is set in broker config (default for development). In production,
  topics should be pre-created with appropriate partition counts.

  ## Partition Key

  Events are partitioned by `agent_id` from the event payload,
  ensuring all events from a single agent land on the same partition
  for ordered replay.
  """

  use GenServer
  require Logger

  @behaviour Hub.EventBus

  @default_brokers [{"localhost", 9094}]
  @default_client_id :ringforge_kafka

  # ── Public API (behaviour callbacks) ──────────────────────────

  @impl Hub.EventBus
  def publish(topic, event) do
    GenServer.call(__MODULE__, {:publish, topic, event})
  end

  @impl Hub.EventBus
  def subscribe(_topic, _opts \\ []) do
    # Full consumer group subscription is Phase 5.
    # For now, this is a no-op — replay reads directly.
    :ok
  end

  @impl Hub.EventBus
  def replay(topic, opts \\ []) do
    GenServer.call(__MODULE__, {:replay, topic, opts}, 15_000)
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

    # Start brod client — if it fails, we log and mark ourselves as degraded
    case :brod.start_client(brokers, client_id, _client_config = []) do
      :ok ->
        Logger.info("[EventBus.Kafka] brod client started → #{inspect(brokers)}")
        {:ok, %{client_id: client_id, brokers: brokers, connected: true}}

      {:error, {:already_started, _pid}} ->
        Logger.info("[EventBus.Kafka] brod client already running")
        {:ok, %{client_id: client_id, brokers: brokers, connected: true}}

      {:error, reason} ->
        Logger.warning("[EventBus.Kafka] Failed to start brod client: #{inspect(reason)} — operating in degraded mode")
        {:ok, %{client_id: client_id, brokers: brokers, connected: false}}
    end
  end

  @impl GenServer
  def handle_call({:publish, topic, _event}, _from, %{connected: false} = state) do
    Logger.warning("[EventBus.Kafka] Not connected — dropping publish to #{topic}")
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:publish, topic, event}, _from, %{client_id: client_id} = state) do
    partition_key = extract_partition_key(event)
    value = Jason.encode!(event)

    case :brod.produce_sync(client_id, topic, :hash, partition_key, value) do
      :ok ->
        {:reply, :ok, state}

      {:error, :unknown_topic_or_partition} ->
        # Topic might not exist yet — try to ensure it exists and retry once
        Logger.info("[EventBus.Kafka] Topic #{topic} not found, attempting auto-create...")

        case ensure_topic(state, topic) do
          :ok ->
            retry = :brod.produce_sync(client_id, topic, :hash, partition_key, value)

            case retry do
              :ok -> {:reply, :ok, state}
              {:error, reason} -> {:reply, {:error, reason}, state}
            end

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        Logger.error("[EventBus.Kafka] Publish failed on #{topic}: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:replay, _topic, _opts}, _from, %{connected: false} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:replay, topic, opts}, _from, %{client_id: client_id} = state) do
    limit = Keyword.get(opts, :limit, 100)
    kinds = Keyword.get(opts, :kinds, nil)

    # Basic replay: read last N messages from partition 0
    # Full multi-partition replay is Phase 5
    result =
      try do
        offset = resolve_offset(client_id, topic, limit)
        fetch_messages(client_id, topic, 0, offset, limit)
      rescue
        e ->
          Logger.error("[EventBus.Kafka] Replay error: #{inspect(e)}")
          {:error, :replay_failed}
      end

    case result do
      {:ok, events} ->
        filtered = maybe_filter_kinds(events, kinds)
        {:reply, {:ok, filtered}, state}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  # ── Private ───────────────────────────────────────────────────

  defp extract_partition_key(event) do
    # Use agent_id as partition key for ordering per-agent
    case event do
      %{"from" => %{"agent_id" => id}} -> id
      %{from: %{agent_id: id}} -> id
      %{"agent_id" => id} -> id
      _ -> "default"
    end
  end

  defp ensure_topic(%{brokers: brokers}, topic) do
    # Attempt to create topic via Kafka admin API
    topic_config = %{
      topic: topic,
      num_partitions: 3,
      replication_factor: 1,
      replica_assignment: [],
      config_entries: []
    }

    case :brod.create_topics(brokers, [topic_config], %{timeout: 5_000}) do
      :ok ->
        Logger.info("[EventBus.Kafka] Created topic: #{topic}")
        # Give Kafka a moment to propagate
        Process.sleep(500)
        :ok

      {:error, :topic_already_exists} ->
        :ok

      {:error, reason} ->
        Logger.warning("[EventBus.Kafka] Could not create topic #{topic}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp resolve_offset(client_id, topic, limit) do
    case :brod.resolve_offset(client_id, topic, 0, :latest) do
      {:ok, latest} ->
        max(0, latest - limit)

      {:error, _} ->
        0
    end
  end

  defp fetch_messages(client_id, topic, partition, offset, limit) do
    case :brod.fetch(client_id, topic, partition, offset, %{max_bytes: 1_048_576}) do
      {:ok, {_high_watermark, messages}} ->
        events =
          messages
          |> Enum.take(limit)
          |> Enum.map(fn msg ->
            value = elem(msg, 4)

            case Jason.decode(value) do
              {:ok, decoded} -> decoded
              _ -> nil
            end
          end)
          |> Enum.reject(&is_nil/1)

        {:ok, events}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_filter_kinds(events, nil), do: events
  defp maybe_filter_kinds(events, []), do: events

  defp maybe_filter_kinds(events, kinds) when is_list(kinds) do
    Enum.filter(events, fn event ->
      Map.get(event, "kind") in kinds
    end)
  end
end
