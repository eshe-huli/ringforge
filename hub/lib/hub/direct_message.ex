defmodule Hub.DirectMessage do
  @moduledoc """
  Agent-to-agent direct messaging with offline queue support.

  Handles building message envelopes, delivering via PubSub,
  queuing messages for offline agents in the Rust store,
  and delivering queued messages on agent reconnect.

  ## Offline Queue

  When a target agent is offline, the message is stored in the Rust
  document store with key `dmq:{fleet_id}:{target_agent_id}:{message_id}`.
  On reconnect, queued messages are delivered if they haven't expired
  (5-minute TTL, checked at delivery time — no background sweeper).

  ## EventBus Persistence

  All direct messages are asynchronously published to EventBus on topic
  `ringforge.{fleet_id}.direct` for durability and history replay.
  """

  require Logger

  alias Hub.StorePort
  alias Hub.FleetPresence
  alias Hub.Auth

  @pubsub Hub.PubSub
  @queue_ttl_seconds 300  # 5 minutes — standard messages
  @queue_ttl_high_priority 86_400  # 24 hours — high/critical priority messages

  # ── Send a direct message ──────────────────────────────────

  @doc """
  Send a direct message from one agent to another within the same fleet.

  Returns `{:ok, %{message_id: ..., status: "delivered"|"queued"}}` on success,
  or `{:error, reason}` if the target agent doesn't exist or is in a different fleet.
  """
  @spec send_message(String.t(), String.t(), String.t(), map(), String.t() | nil) ::
          {:ok, map()} | {:error, String.t()}
  def send_message(fleet_id, from_agent_id, to_agent_id, message, correlation_id \\ nil) do
    # 1. Validate target agent exists and is in the same fleet
    case validate_target(fleet_id, to_agent_id) do
      {:error, reason} ->
        {:error, reason}

      :ok ->
        message_id = "msg_" <> gen_uuid()
        from_name = get_agent_name_from_presence(fleet_id, from_agent_id) || from_agent_id
        now = DateTime.utc_now() |> DateTime.to_iso8601()

        envelope = %{
          "message_id" => message_id,
          "from" => %{
            "agent_id" => from_agent_id,
            "name" => from_name
          },
          "to" => to_agent_id,
          "correlation_id" => correlation_id,
          "message" => message,
          "timestamp" => now
        }

        # 2. Check if target is online
        online = agent_online?(fleet_id, to_agent_id)

        # 3. Deliver via PubSub
        Phoenix.PubSub.broadcast(
          @pubsub,
          "fleet:#{fleet_id}:agent:#{to_agent_id}",
          {:direct_message, envelope}
        )

        status = if online, do: "delivered", else: "queued"

        # 4. If offline, queue in Rust store
        if not online do
          queue_message(fleet_id, to_agent_id, message_id, envelope)
        end

        # 5. Async persist to EventBus
        persist_to_event_bus(fleet_id, envelope)

        # 6. Send notification to target agent
        Task.start(fn ->
          Hub.Messaging.Notifications.notify(fleet_id, to_agent_id, :dm_received, %{
            "from" => from_agent_id,
            "from_name" => from_name,
            "message_id" => message_id,
            "preview" => truncate_preview(message),
            "timestamp" => now
          })
        end)

        {:ok, %{message_id: message_id, status: status}}
    end
  end

  # ── Offline Queue ──────────────────────────────────────────

  @doc """
  Queue a message for offline delivery in the Rust store.
  Priority "high" or "critical" messages get a 24h TTL instead of 5min.
  """
  def queue_message(fleet_id, target_agent_id, message_id, envelope) do
    queue_key = "dmq:#{fleet_id}:#{target_agent_id}:#{message_id}"
    meta_json = Jason.encode!(envelope)

    case StorePort.put_document(queue_key, meta_json, <<>>) do
      :ok -> :ok
      {:error, reason} ->
        Logger.warning("[DirectMessage] Failed to queue message: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  List all queued (non-expired) messages for an agent without delivering them.
  Useful for agents to check their queue explicitly.
  """
  @spec list_queued(String.t(), String.t()) :: [map()]
  def list_queued(fleet_id, agent_id) do
    prefix = "dmq:#{fleet_id}:#{agent_id}:"

    case StorePort.list_documents() do
      {:ok, ids} ->
        ids
        |> Enum.filter(&String.starts_with?(&1, prefix))
        |> Enum.reduce([], fn queue_key, acc ->
          case fetch_queued_message(queue_key) do
            {:ok, envelope} ->
              if message_expired?(envelope), do: acc, else: [envelope | acc]

            :not_found ->
              acc
          end
        end)
        |> Enum.sort_by(& &1["timestamp"])

      {:error, _} ->
        []
    end
  end

  @doc """
  Deliver all queued messages to an agent that just came online.

  Called asynchronously from FleetChannel.join. Delivers messages
  that haven't expired (< #{@queue_ttl_seconds}s old), deletes them
  from the queue, and discards expired ones.

  Returns the list of delivered message envelopes.
  """
  @spec deliver_queued(String.t(), String.t()) :: [map()]
  def deliver_queued(fleet_id, agent_id) do
    prefix = "dmq:#{fleet_id}:#{agent_id}:"

    case StorePort.list_documents() do
      {:ok, ids} ->
        queue_ids = Enum.filter(ids, &String.starts_with?(&1, prefix))

        Enum.reduce(queue_ids, [], fn queue_key, delivered ->
          case fetch_queued_message(queue_key) do
            {:ok, envelope} ->
              if message_expired?(envelope) do
                # Expired — just delete
                StorePort.delete_document(queue_key)
                delivered
              else
                # Deliver via PubSub
                Phoenix.PubSub.broadcast(
                  @pubsub,
                  "fleet:#{fleet_id}:agent:#{agent_id}",
                  {:direct_message, envelope}
                )

                # Clean up from queue
                StorePort.delete_document(queue_key)
                [envelope | delivered]
              end

            :not_found ->
              delivered
          end
        end)

      {:error, reason} ->
        Logger.warning("[DirectMessage] Failed to list queue: #{inspect(reason)}")
        []
    end
  end

  # ── History ────────────────────────────────────────────────

  @doc """
  Retrieve conversation history between two agents from EventBus.

  Returns messages where (from == agent_a AND to == agent_b) OR
  (from == agent_b AND to == agent_a), sorted by timestamp ascending.
  """
  @spec history(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def history(fleet_id, agent_a, agent_b, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    # Try StorePort first (persistent)
    pair = Enum.sort([agent_a, agent_b]) |> Enum.join(":")
    conv_key = "conv:#{fleet_id}:#{pair}"

    case StorePort.get_document(conv_key) do
      {:ok, data} ->
        case Jason.decode(data) do
          {:ok, messages} when is_list(messages) ->
            {:ok, Enum.take(messages, -limit)}
          _ ->
            {:ok, []}
        end

      _ ->
        # Fallback to EventBus (volatile ETS)
        bus_topic = "ringforge.#{fleet_id}.direct"
        case Hub.EventBus.replay(bus_topic, limit: limit * 10) do
          {:ok, events} ->
            conversation =
              events
              |> Enum.filter(fn event ->
                from_id = get_in(event, ["from", "agent_id"])
                to_id = event["to"]
                (from_id == agent_a and to_id == agent_b) or
                  (from_id == agent_b and to_id == agent_a)
              end)
              |> Enum.take(-limit)
            {:ok, conversation}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # ── Private Helpers ────────────────────────────────────────

  defp validate_target(_fleet_id, "dashboard"), do: :ok
  defp validate_target(fleet_id, to_agent_id) do
    case Auth.find_agent(to_agent_id) do
      {:ok, agent} ->
        if agent.fleet_id && fleet_id_matches?(agent, fleet_id) do
          :ok
        else
          {:error, "target agent is not in this fleet"}
        end

      {:error, :not_found} ->
        # Also check presence — agent may be connected even if DB lookup fails
        if agent_online?(fleet_id, to_agent_id) do
          :ok
        else
          {:error, "agent not found"}
        end
    end
  end

  defp fleet_id_matches?(agent, fleet_id) do
    # Agent's fleet association — compare fleet.id (UUID) with fleet_id
    # The fleet_id in the channel is the Fleet's string id from the DB
    cond do
      agent.fleet && agent.fleet.id == fleet_id -> true
      agent.fleet_id == fleet_id -> true
      true -> false
    end
  end

  defp agent_online?(fleet_id, agent_id) do
    topic = "fleet:#{fleet_id}"

    case FleetPresence.list(topic) do
      presences when is_map(presences) ->
        Map.has_key?(presences, agent_id)

      _ ->
        false
    end
  end

  defp get_agent_name_from_presence(fleet_id, agent_id) do
    topic = "fleet:#{fleet_id}"

    case FleetPresence.list(topic) do
      presences when is_map(presences) ->
        case Map.get(presences, agent_id) do
          %{metas: [meta | _]} -> meta[:name] || meta["name"]
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp fetch_queued_message(queue_key) do
    case StorePort.get_document(queue_key) do
      {:ok, %{meta: meta}} when byte_size(meta) > 0 ->
        {:ok, Jason.decode!(meta)}

      :not_found ->
        :not_found

      {:error, _} ->
        :not_found
    end
  end

  defp message_expired?(envelope) do
    case envelope["timestamp"] do
      nil ->
        true

      ts_string ->
        case DateTime.from_iso8601(ts_string) do
          {:ok, ts, _offset} ->
            age = DateTime.diff(DateTime.utc_now(), ts, :second)
            ttl = ttl_for_envelope(envelope)
            age > ttl

          _ ->
            true
        end
    end
  end

  # High/critical priority messages get extended TTL (24h)
  defp ttl_for_envelope(envelope) do
    priority = get_in(envelope, ["message", "priority"])

    if priority in ["high", "critical"] do
      @queue_ttl_high_priority
    else
      @queue_ttl_seconds
    end
  end

  defp persist_to_event_bus(fleet_id, envelope) do
    bus_topic = "ringforge.#{fleet_id}.direct"

    Task.start(fn ->
      # 1. EventBus (ETS — fast but volatile)
      case Hub.EventBus.publish(bus_topic, envelope) do
        :ok -> :ok
        {:error, reason} ->
          Logger.warning("[DirectMessage] EventBus publish failed: #{inspect(reason)}")
      end

      # 2. StorePort (Rust store — persistent across restarts)
      persist_to_store(fleet_id, envelope)
    end)
  end

  defp persist_to_store(fleet_id, envelope) do
    from_id = get_in(envelope, ["from", "agent_id"]) || "unknown"
    to_id = envelope["to"] || "unknown"
    # Canonical conversation key: sorted pair
    pair = Enum.sort([from_id, to_id]) |> Enum.join(":")
    conv_key = "conv:#{fleet_id}:#{pair}"

    existing = case StorePort.get_document(conv_key) do
      {:ok, data} ->
        case Jason.decode(data) do
          {:ok, list} when is_list(list) -> list
          _ -> []
        end
      _ -> []
    end

    # Append and keep last 200 messages per conversation
    updated = (existing ++ [envelope]) |> Enum.take(-200)
    StorePort.put_document(conv_key, Jason.encode!(updated))
  rescue
    _ -> :ok
  end

  defp truncate_preview(message) when is_map(message) do
    body = Map.get(message, "body") || Map.get(message, :body) || ""
    truncate_preview(body)
  end

  defp truncate_preview(text) when is_binary(text) do
    if String.length(text) > 80 do
      String.slice(text, 0, 80) <> "…"
    else
      text
    end
  end

  defp truncate_preview(_), do: ""

  defp gen_uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    [
      Base.encode16(<<a::32>>, case: :lower),
      Base.encode16(<<b::16>>, case: :lower),
      Base.encode16(<<c::16>>, case: :lower),
      Base.encode16(<<d::16>>, case: :lower),
      Base.encode16(<<e::48>>, case: :lower)
    ]
    |> Enum.join("-")
  end
end
