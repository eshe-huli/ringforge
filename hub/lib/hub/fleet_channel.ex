defmodule Hub.FleetChannel do
  @moduledoc """
  Phoenix Channel for fleet-scoped agent presence and coordination.

  Topic pattern: `fleet:{fleet_id}` — agents join their fleet's channel
  after authenticating via `Hub.Socket`.

  ## Presence Lifecycle

  1. Agent connects via WebSocket (auth handled by Socket)
  2. Agent joins `fleet:{fleet_id}` with join payload containing state/capabilities
  3. Hub tracks presence via `Hub.FleetPresence` (Phoenix.Presence)
  4. Hub broadcasts `presence:joined` to all fleet members
  5. Agent receives current roster in join reply
  6. Agent can send `presence:update` to change state/task/load
  7. On disconnect, Hub broadcasts `presence:left` and updates `last_seen_at`

  ## Wire Protocol

  All messages follow the custom JSON envelope format:

      %{"type" => "presence", "action" | "event" => "...", "payload" => %{}}

  ## Valid States

  "online", "busy", "away", "offline"
  """
  use Phoenix.Channel

  require Logger

  alias Hub.FleetPresence
  alias Hub.Auth
  alias Hub.DirectMessage
  alias Hub.EventReplay

  @valid_states ~w(online busy away offline)
  @valid_activity_kinds ~w(task_started task_progress task_completed task_failed discovery question alert custom)

  # Idempotency supported on: activity:broadcast, memory:set, direct:send, group:create

  # ── Join ────────────────────────────────────────────────────

  @impl true
  def join("fleet:lobby", payload, socket) do
    # Lobby topic — resolve to the agent's actual fleet from socket assigns.
    # This allows SDK clients to connect without knowing their fleet_id upfront.
    fleet_id = socket.assigns.fleet_id

    if not quota_ok?(socket.assigns.tenant_id, :connected_agents) do
      {:error, %{
        reason: "quota_exceeded",
        resource: "connected_agents",
        message: "Agent connection limit reached for your plan.",
        fix: "Disconnect idle agents or upgrade your plan. Check usage at /dashboard → Quotas."
      }}
    else
      Hub.Quota.increment(socket.assigns.tenant_id, :connected_agents)
      # Re-assign the topic so broadcasts go to the real fleet topic
      socket = assign(socket, :resolved_fleet_topic, "fleet:#{fleet_id}")
      send(self(), {:after_join, payload})
      {:ok, %{fleet_id: fleet_id, topic: "fleet:#{fleet_id}"}, socket}
    end
  end

  def join("fleet:" <> fleet_id, payload, socket) do
    # Verify the socket's fleet_id matches the requested topic
    cond do
      socket.assigns.fleet_id != fleet_id ->
        {:error, %{
          reason: "fleet_id_mismatch",
          message: "Your API key belongs to fleet '#{socket.assigns.fleet_id}', but you tried to join 'fleet:#{fleet_id}'.",
          fix: "Set RINGFORGE_FLEET_ID=#{socket.assigns.fleet_id} or pass --fleet #{socket.assigns.fleet_id}",
          your_fleet_id: socket.assigns.fleet_id
        }}

      not quota_ok?(socket.assigns.tenant_id, :connected_agents) ->
        {:error, %{
          reason: "quota_exceeded",
          resource: "connected_agents",
          message: "Agent connection limit reached for your plan.",
          fix: "Disconnect idle agents or upgrade your plan. Check usage at /dashboard → Quotas."
        }}

      true ->
        Hub.Quota.increment(socket.assigns.tenant_id, :connected_agents)
        send(self(), {:after_join, payload})
        {:ok, socket}
    end
  end

  @impl true
  def handle_info({:after_join, payload}, socket) do
    agent = fetch_agent(socket)
    join_payload = Map.get(payload, "payload", %{})

    # Sync name/framework/capabilities from join payload back to DB
    maybe_sync_agent_metadata(agent, join_payload)

    # Build presence metadata from join payload + agent DB record
    meta = build_meta(agent, join_payload)

    # Track in Phoenix.Presence
    {:ok, _ref} = FleetPresence.track(socket, socket.assigns.agent_id, meta)

    # Start session tracking (async to avoid blocking join)
    socket = if agent do
      Task.start(fn ->
        case Auth.start_agent_session(agent.id, agent.fleet_id) do
          {:ok, session} ->
            Logger.debug("[FleetChannel] Session #{session.id} started for #{agent.agent_id}")
          _ -> :ok
        end
      end)

      # Store agent DB id for session lookup on terminate
      assign(socket, :agent_db_id, agent.id)
    else
      socket
    end

    # Emit telemetry
    Hub.Telemetry.execute([:hub, :channel, :join], %{count: 1}, %{
      agent_id: socket.assigns.agent_id,
      fleet_id: socket.assigns.fleet_id
    })

    # Broadcast joined event to all fleet members
    broadcast!(socket, "presence:joined", %{
      "type" => "presence",
      "event" => "joined",
      "payload" => presence_payload(socket.assigns.agent_id, meta)
    })

    # Reply with current roster (sent as a push since we're in handle_info)
    roster = build_roster(socket)

    push(socket, "presence:roster", %{
      "type" => "presence",
      "event" => "roster",
      "payload" => %{"agents" => roster}
    })

    # Subscribe to agent-specific direct delivery topic
    Phoenix.PubSub.subscribe(Hub.PubSub, "fleet:#{socket.assigns.fleet_id}:agent:#{socket.assigns.agent_id}")

    # Squad PubSub subscription — if agent has a squad_id, subscribe to squad topic
    socket = if squad_id = socket.assigns[:squad_id] do
      Phoenix.PubSub.subscribe(Hub.PubSub, "squad:#{squad_id}")

      # Broadcast squad presence to squadmates
      squad_meta = %{
        "agent_id" => socket.assigns.agent_id,
        "name" => meta[:name],
        "state" => meta[:state],
        "task" => meta[:task],
        "connected_at" => meta[:connected_at]
      }

      Phoenix.PubSub.broadcast(Hub.PubSub, "squad:#{squad_id}", {:squad_presence, %{
        "type" => "squad",
        "event" => "presence",
        "payload" => Map.put(squad_meta, "action", "joined")
      }})

      assign(socket, :squad_id, squad_id)
    else
      socket
    end

    # Ensure webhook subscriber is listening to this fleet's topic
    Hub.WebhookSubscriber.subscribe_fleet(socket.assigns.fleet_id)

    # Push role context if agent has a role assigned
    if agent do
      case Hub.ContextInjection.build_role_context(agent) do
        nil -> :ok
        role_ctx ->
          push(socket, "role:context", %{
            "type" => "role",
            "event" => "context",
            "payload" => role_ctx
          })
      end
    end

    # Deliver queued direct messages (async, don't block join)
    fleet_id = socket.assigns.fleet_id
    agent_id = socket.assigns.agent_id

    Task.start(fn ->
      queued = DirectMessage.deliver_queued(fleet_id, agent_id)

      if queued != [] do
        Logger.info("[FleetChannel] Delivered #{length(queued)} queued message(s) to #{agent_id}")
      end
    end)

    {:noreply, socket}
  end

  # Tagged activity delivery (from PubSub subscription)
  @impl true
  def handle_info({:tagged_activity, msg}, socket) do
    push(socket, "activity:broadcast", msg)
    {:noreply, socket}
  end

  # Direct activity delivery (from PubSub subscription)
  @impl true
  def handle_info({:direct_activity, msg}, socket) do
    push(socket, "activity:broadcast", msg)
    {:noreply, socket}
  end

  # Direct message delivery (from PubSub — another agent sent us a DM)
  def handle_info({:direct_message, envelope}, socket) do
    push(socket, "direct:message", %{
      "type" => "direct",
      "event" => "message",
      "payload" => Map.drop(envelope, ["to"])
    })

    # Send delivery receipt back to sender
    if sender_id = get_in(envelope, ["from", "agent_id"]) do
      Phoenix.PubSub.broadcast(
        Hub.PubSub,
        "fleet:#{socket.assigns.fleet_id}:agent:#{sender_id}",
        {:message_receipt, %{
          "message_id" => envelope["message_id"],
          "to" => socket.assigns.agent_id,
          "status" => "delivered",
          "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
        }}
      )
    end

    {:noreply, socket}
  end

  # Delivery receipt (from PubSub — target agent received our message)
  def handle_info({:message_receipt, receipt}, socket) do
    push(socket, "message:receipt", %{
      "type" => "message",
      "event" => "receipt",
      "payload" => receipt
    })

    {:noreply, socket}
  end

  # Read receipt (from PubSub — target agent read our message)
  def handle_info({:message_read, data}, socket) do
    push(socket, "message:read", %{
      "type" => "message",
      "event" => "read",
      "payload" => data
    })

    {:noreply, socket}
  end

  # Typing indicator (from PubSub — another agent is typing to us)
  def handle_info({:typing_indicator, data}, socket) do
    push(socket, "message:typing", %{
      "type" => "message",
      "event" => "typing",
      "payload" => data
    })

    {:noreply, socket}
  end

  # Notification delivery (from PubSub — new notification for this agent)
  def handle_info({:notification, notification}, socket) do
    push(socket, "notification", %{
      "type" => "notification",
      "event" => "new",
      "payload" => notification
    })

    {:noreply, socket}
  end

  # Quota warnings (from PubSub)
  def handle_info({:quota_warning, msg}, socket) do
    push(socket, "system:quota_warning", msg)
    {:noreply, socket}
  end

  # Task assignment delivery (from TaskSupervisor via PubSub)
  def handle_info({:task_assigned, msg}, socket) do
    push(socket, "task:assigned", msg)
    {:noreply, socket}
  end

  # Task result delivery (from TaskSupervisor via PubSub)
  def handle_info({:task_result, msg}, socket) do
    push(socket, "task:result", msg)
    {:noreply, socket}
  end

  # Memory change delivery (from PubSub subscription)
  def handle_info({:memory_changed, event}, socket) do
    patterns = Map.get(socket.assigns, :memory_patterns, [])

    # If no patterns are subscribed, this process shouldn't receive this,
    # but check anyway. When patterns exist, filter by match.
    should_push =
      patterns == [] or
        Enum.any?(patterns, fn %{pattern: pat, events: events} ->
          action_match = event.action in events
          key_match = pattern_matches?(pat, event.key)
          action_match and key_match
        end)

    if should_push do
      push(socket, "memory:changed", %{
        "type" => "memory",
        "event" => "changed",
        "payload" => %{
          "key" => event.key,
          "action" => event.action,
          "author" => event.author,
          "timestamp" => event.timestamp
        }
      })
    end

    {:noreply, socket}
  end

  # ── Squad PubSub delivery ────────────────────────────────────

  # Squad presence changes (from PubSub)
  def handle_info({:squad_presence, msg}, socket) do
    push(socket, "squad:presence", msg)
    {:noreply, socket}
  end

  # Squad memory changes (from PubSub)
  def handle_info({:squad_memory_changed, event}, socket) do
    push(socket, "squad:memory:changed", %{
      "type" => "squad",
      "event" => "memory:changed",
      "payload" => %{
        "key" => event.key,
        "action" => event.action,
        "author" => event.author,
        "squad_id" => event.squad_id,
        "timestamp" => event.timestamp
      }
    })

    {:noreply, socket}
  end

  # Squad activity delivery (from PubSub)
  def handle_info({:squad_activity, msg}, socket) do
    push(socket, "squad:activity:broadcast", msg)
    {:noreply, socket}
  end

  # Squad task assignment delivery (from PubSub)
  def handle_info({:squad_task_assigned, msg}, socket) do
    push(socket, "squad:task:assigned", msg)
    {:noreply, socket}
  end

  # ── presence:update — client updates their state ───────────

  @impl true
  def handle_in("presence:update", %{"payload" => update_payload}, socket) do
    state = Map.get(update_payload, "state")

    if state && state not in @valid_states do
      {:reply, {:error, %{
        reason: "invalid_state",
        message: "State '#{state}' is not valid. Must be one of: #{Enum.join(@valid_states, ", ")}.",
        fix: "Send presence:update with payload.state set to 'online', 'busy', 'away', or 'offline'."
      }}, socket}
    else
      # Get current meta and merge updates
      current_meta = get_current_meta(socket)

      updated_meta =
        current_meta
        |> maybe_update(:state, update_payload)
        |> maybe_update(:task, update_payload)
        |> maybe_update(:load, update_payload)
        |> maybe_update(:model, update_payload)
        |> maybe_update(:metadata, update_payload)

      # Update presence tracking
      FleetPresence.update(socket, socket.assigns.agent_id, updated_meta)

      # Broadcast state change to fleet
      state_payload = %{
        "agent_id" => socket.assigns.agent_id,
        "name" => updated_meta[:name],
        "state" => updated_meta[:state],
        "task" => updated_meta[:task],
        "load" => updated_meta[:load],
        "model" => updated_meta[:model]
      }

      broadcast!(socket, "presence:state_changed", %{
        "type" => "presence",
        "event" => "state_changed",
        "payload" => state_payload
      })

      # Also broadcast to squad topic if agent is in a squad
      if squad_id = socket.assigns[:squad_id] do
        Phoenix.PubSub.broadcast(Hub.PubSub, "squad:#{squad_id}", {:squad_presence, %{
          "type" => "squad",
          "event" => "presence",
          "payload" => Map.put(state_payload, "action", "state_changed")
        }})
      end

      {:reply, {:ok, %{status: "updated"}}, socket}
    end
  end

  # Handle presence:update without nested payload (flat format)
  def handle_in("presence:update", payload, socket) when is_map(payload) do
    handle_in("presence:update", %{"payload" => payload}, socket)
  end

  # ── presence:roster — client requests full roster ──────────

  def handle_in("presence:roster", _payload, socket) do
    roster = build_roster(socket)

    {:reply, {:ok, %{
      "type" => "presence",
      "event" => "roster",
      "payload" => %{"agents" => roster}
    }}, socket}
  end

  # ── activity:broadcast — publish activity event ─────────────

  def handle_in("activity:broadcast", %{"payload" => payload} = raw, socket) do
    idem_key = extract_idempotency_key(raw, socket)

    case check_idempotency(idem_key, socket) do
      {:hit, cached_reply, socket} ->
        {:reply, {:ok, cached_reply}, socket}

      :miss ->
        kind = Map.get(payload, "kind")

        cond do
          kind not in @valid_activity_kinds ->
            {:reply, {:error, %{
              reason: "invalid_activity_kind",
              message: "Activity kind '#{kind}' is not valid. Must be one of: #{Enum.join(@valid_activity_kinds, ", ")}.",
              fix: "Set payload.kind to a valid value. Use 'custom' for generic events."
            }}, socket}

          not quota_ok?(socket.assigns.tenant_id, :messages_today) ->
            {:reply, {:error, %{
              reason: "quota_exceeded",
              resource: "messages_today",
              message: "Daily message quota reached.",
              fix: "Wait until quota resets or upgrade your plan. Check usage at /dashboard → Quotas."
            }}, socket}

          true ->
            Hub.Quota.increment(socket.assigns.tenant_id, :messages_today)
            event_id = "evt_" <> gen_uuid()
            scope = Map.get(payload, "scope", "fleet")

            event = %{
              "event_id" => event_id,
              "from" => %{
                "agent_id" => socket.assigns.agent_id,
                "name" => get_agent_name(socket)
              },
              "kind" => kind,
              "description" => Map.get(payload, "description", ""),
              "tags" => Map.get(payload, "tags", []),
              "data" => Map.get(payload, "data", %{}),
              "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
            }

            broadcast_msg = %{
              "type" => "activity",
              "event" => "broadcast",
              "payload" => event
            }

            # Scope-based delivery
            case scope do
              "fleet" ->
                broadcast!(socket, "activity:broadcast", broadcast_msg)

              "tagged" ->
                tags = Map.get(payload, "tags", [])
                broadcast_to_tagged(socket, tags, broadcast_msg)

              "direct" ->
                to = Map.get(payload, "to")

                if to do
                  broadcast_to_agent(socket, to, broadcast_msg)
                else
                  broadcast!(socket, "activity:broadcast", broadcast_msg)
                end

              _ ->
                broadcast!(socket, "activity:broadcast", broadcast_msg)
            end

            # Async publish to EventBus for durability — never block the channel
            fleet_id = socket.assigns.fleet_id
            bus_topic = "ringforge.#{fleet_id}.activity"

            Task.start(fn ->
              case Hub.EventBus.publish(bus_topic, event) do
                :ok -> :ok
                {:error, reason} ->
                  Logger.warning("[FleetChannel] EventBus publish failed: #{inspect(reason)}")
              end
            end)

            reply = %{event_id: event_id}
            store_idempotency(idem_key, reply)
            {:reply, {:ok, reply}, socket}
        end
    end
  end

  def handle_in("activity:broadcast", payload, socket) when is_map(payload) do
    handle_in("activity:broadcast", %{"payload" => payload}, socket)
  end

  # ── activity:subscribe — subscribe to tagged activity ──────

  def handle_in("activity:subscribe", %{"payload" => %{"tags" => tags}}, socket) when is_list(tags) do
    current = Map.get(socket.assigns, :activity_tags, MapSet.new())
    new_tags = Enum.reject(tags, &MapSet.member?(current, &1))

    # Subscribe this channel process to tag-specific PubSub topics
    Enum.each(new_tags, fn tag ->
      Phoenix.PubSub.subscribe(Hub.PubSub, "fleet:#{socket.assigns.fleet_id}:tag:#{tag}")
    end)

    updated = Enum.reduce(tags, current, &MapSet.put(&2, &1))
    socket = assign(socket, :activity_tags, updated)
    {:reply, {:ok, %{subscribed_tags: MapSet.to_list(updated)}}, socket}
  end

  def handle_in("activity:subscribe", _payload, socket) do
    {:reply, {:error, %{reason: "payload must include \"tags\" list"}}, socket}
  end

  # ── activity:unsubscribe — remove tag subscriptions ────────

  def handle_in("activity:unsubscribe", %{"payload" => %{"tags" => tags}}, socket) when is_list(tags) do
    current = Map.get(socket.assigns, :activity_tags, MapSet.new())

    # Unsubscribe from tag-specific PubSub topics
    Enum.each(tags, fn tag ->
      if MapSet.member?(current, tag) do
        Phoenix.PubSub.unsubscribe(Hub.PubSub, "fleet:#{socket.assigns.fleet_id}:tag:#{tag}")
      end
    end)

    updated = Enum.reduce(tags, current, &MapSet.delete(&2, &1))
    socket = assign(socket, :activity_tags, updated)
    {:reply, {:ok, %{subscribed_tags: MapSet.to_list(updated)}}, socket}
  end

  def handle_in("activity:unsubscribe", _payload, socket) do
    {:reply, {:error, %{reason: "payload must include \"tags\" list"}}, socket}
  end

  # ── activity:history — replay recent events ────────────────

  def handle_in("activity:history", %{"payload" => payload}, socket) do
    fleet_id = socket.assigns.fleet_id
    bus_topic = "ringforge.#{fleet_id}.activity"
    limit = Map.get(payload, "limit", 50)
    kinds = Map.get(payload, "kinds")

    opts = [limit: limit]
    opts = if kinds, do: Keyword.put(opts, :kinds, kinds), else: opts

    case Hub.EventBus.replay(bus_topic, opts) do
      {:ok, events} ->
        {:reply, {:ok, %{
          "type" => "activity",
          "event" => "history",
          "payload" => %{"events" => events, "count" => length(events)}
        }}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: "replay failed: #{inspect(reason)}"}}, socket}
    end
  end

  def handle_in("activity:history", _payload, socket) do
    handle_in("activity:history", %{"payload" => %{}}, socket)
  end

  # ── memory:set — create/update a memory entry ───────────────

  def handle_in("memory:set", %{"payload" => payload} = raw, socket) do
    idem_key = extract_idempotency_key(raw, socket)

    case check_idempotency(idem_key, socket) do
      {:hit, cached_reply, socket} ->
        {:reply, {:ok, cached_reply}, socket}

      :miss ->
        key = Map.get(payload, "key")

        cond do
          is_nil(key) or key == "" ->
            {:reply, {:error, %{
              reason: "missing_key",
              message: "Memory entries require a 'key' field.",
              fix: "Add payload.key = 'my/key/path' — use forward slashes for namespacing."
            }}, socket}

          not quota_ok?(socket.assigns.tenant_id, :memory_entries) ->
            {:reply, {:error, %{
              reason: "quota_exceeded",
              resource: "memory_entries",
              message: "Memory entry quota reached.",
              fix: "Delete unused entries with memory:delete or upgrade your plan."
            }}, socket}

          true ->
            Hub.Quota.increment(socket.assigns.tenant_id, :memory_entries)
            params = Map.put(payload, "author", socket.assigns.agent_id)

            case Hub.Memory.set(socket.assigns.fleet_id, key, params) do
              {:ok, entry} ->
                reply = %{id: entry["id"], key: entry["key"], version: 1}
                store_idempotency(idem_key, reply)
                {:reply, {:ok, reply}, socket}
            end
        end
    end
  end

  def handle_in("memory:set", payload, socket) when is_map(payload) do
    handle_in("memory:set", %{"payload" => payload}, socket)
  end

  # ── memory:get — retrieve a memory entry ───────────────────

  def handle_in("memory:get", %{"payload" => %{"key" => key}}, socket) do
    case Hub.Memory.get(socket.assigns.fleet_id, key) do
      {:ok, entry} ->
        {:reply, {:ok, %{type: "memory", event: "entry", payload: entry}}, socket}

      :not_found ->
        {:reply, {:error, %{reason: "not_found"}}, socket}
    end
  end

  def handle_in("memory:get", _payload, socket) do
    {:reply, {:error, %{reason: "payload must include \"key\""}}, socket}
  end

  # ── memory:delete — delete a memory entry ──────────────────

  def handle_in("memory:delete", %{"payload" => %{"key" => key}}, socket) do
    case Hub.Memory.delete(socket.assigns.fleet_id, key) do
      :ok ->
        {:reply, {:ok, %{deleted: true}}, socket}

      :not_found ->
        {:reply, {:error, %{reason: "not_found"}}, socket}
    end
  end

  def handle_in("memory:delete", _payload, socket) do
    {:reply, {:error, %{reason: "payload must include \"key\""}}, socket}
  end

  # ── memory:list — list memory entries ──────────────────────

  def handle_in("memory:list", %{"payload" => payload}, socket) do
    opts =
      []
      |> maybe_opt(:limit, Map.get(payload, "limit"))
      |> maybe_opt(:offset, Map.get(payload, "offset"))
      |> maybe_opt(:tags, Map.get(payload, "tags"))
      |> maybe_opt(:author, Map.get(payload, "author"))

    {:ok, entries} = Hub.Memory.list(socket.assigns.fleet_id, opts)

    {:reply, {:ok, %{
      type: "memory",
      event: "list",
      payload: %{entries: entries, count: length(entries)}
    }}, socket}
  end

  def handle_in("memory:list", _payload, socket) do
    handle_in("memory:list", %{"payload" => %{}}, socket)
  end

  # ── memory:query — search memory entries ───────────────────

  def handle_in("memory:query", %{"payload" => payload}, socket) do
    sort =
      case Map.get(payload, "sort") do
        "relevance" -> :relevance
        "created_at" -> :created_at
        "updated_at" -> :updated_at
        "access_count" -> :access_count
        _ -> nil
      end

    opts =
      []
      |> maybe_opt(:limit, Map.get(payload, "limit"))
      |> maybe_opt(:tags, Map.get(payload, "tags"))
      |> maybe_opt(:text_search, Map.get(payload, "text_search"))
      |> maybe_opt(:author, Map.get(payload, "author"))
      |> maybe_opt(:since, Map.get(payload, "since"))
      |> maybe_opt(:sort, sort)

    {:ok, entries} = Hub.Memory.query(socket.assigns.fleet_id, opts)

    {:reply, {:ok, %{
      type: "memory",
      event: "query",
      payload: %{entries: entries, count: length(entries)}
    }}, socket}
  end

  def handle_in("memory:query", _payload, socket) do
    handle_in("memory:query", %{"payload" => %{}}, socket)
  end

  # ── memory:subscribe — subscribe to memory changes ─────────

  def handle_in("memory:subscribe", %{"payload" => %{"pattern" => pattern}}, socket) do
    fleet_id = socket.assigns.fleet_id
    topic = Hub.Memory.subscribe_pattern(fleet_id, pattern)

    Phoenix.PubSub.subscribe(Hub.PubSub, topic)

    # Track subscribed patterns for pattern matching in handle_info
    current_patterns = Map.get(socket.assigns, :memory_patterns, [])
    events = Map.get(socket.assigns[:memory_subscribe_payload] || %{}, "events", ["set", "delete"])

    pattern_entry = %{pattern: pattern, events: events, topic: topic}

    socket =
      socket
      |> assign(:memory_patterns, [pattern_entry | current_patterns])

    {:reply, {:ok, %{subscribed: pattern, topic: topic}}, socket}
  end

  def handle_in("memory:subscribe", _payload, socket) do
    {:reply, {:error, %{reason: "payload must include \"pattern\""}}, socket}
  end

  # ── direct:send — send a direct message to another agent ──

  def handle_in("direct:send", %{"payload" => payload} = raw, socket) do
    idem_key = extract_idempotency_key(raw, socket)

    case check_idempotency(idem_key, socket) do
      {:hit, cached_reply, socket} ->
        {:reply, {:ok, cached_reply}, socket}

      :miss ->
        to = Map.get(payload, "to")
        correlation_id = Map.get(payload, "correlation_id")
        message = Map.get(payload, "message", %{})

        cond do
          is_nil(to) or to == "" ->
            {:reply, {:error, %{
              reason: "missing_recipient",
              message: "Direct message requires a 'to' field with the target agent_id.",
              fix: "Add payload.to = 'ag_...' with the recipient's agent ID. Use presence:roster to find agent IDs."
            }}, socket}

          to == socket.assigns.agent_id ->
            {:reply, {:error, %{
              reason: "self_message",
              message: "Cannot send a direct message to yourself.",
              fix: "Use a different agent_id in the 'to' field."
            }}, socket}

          not quota_ok?(socket.assigns.tenant_id, :messages_today) ->
            {:reply, {:error, %{
              reason: "quota_exceeded",
              resource: "messages_today",
              message: "Daily message quota reached.",
              fix: "Wait until quota resets or upgrade your plan."
            }}, socket}

          true ->
            Hub.Quota.increment(socket.assigns.tenant_id, :messages_today)
            Hub.Quota.increment(socket.assigns.tenant_id, :messages_today)
            # Increment agent's lifetime message counter
            Task.start(fn -> Auth.increment_agent_messages(socket.assigns.agent_id) end)

            Hub.Telemetry.execute([:hub, :message, :sent], %{count: 1}, %{
              agent_id: socket.assigns.agent_id,
              fleet_id: socket.assigns.fleet_id,
              to: to
            })

            case DirectMessage.send_message(
                   socket.assigns.fleet_id,
                   socket.assigns.agent_id,
                   to,
                   message,
                   correlation_id
                 ) do
              {:ok, result} ->
                reply = %{
                  "type" => "direct",
                  "event" => "delivered",
                  "payload" => %{
                    "message_id" => result.message_id,
                    "to" => to,
                    "status" => result.status
                  }
                }
                store_idempotency(idem_key, reply)
                {:reply, {:ok, reply}, socket}

              {:error, reason} ->
                {:reply, {:ok, %{
                  "type" => "direct",
                  "event" => "delivered",
                  "payload" => %{
                    "message_id" => nil,
                    "to" => to,
                    "status" => "failed",
                    "reason" => reason
                  }
                }}, socket}
            end
        end
    end
  end

  def handle_in("direct:send", payload, socket) when is_map(payload) do
    handle_in("direct:send", %{"payload" => payload}, socket)
  end

  # ── direct:history — conversation history between two agents ─

  def handle_in("direct:history", %{"payload" => payload}, socket) do
    with_agent = Map.get(payload, "with")
    limit = Map.get(payload, "limit", 50)

    if is_nil(with_agent) or with_agent == "" do
      {:reply, {:error, %{reason: "\"with\" agent_id is required"}}, socket}
    else
      case DirectMessage.history(
             socket.assigns.fleet_id,
             socket.assigns.agent_id,
             with_agent,
             limit: limit
           ) do
        {:ok, messages} ->
          {:reply, {:ok, %{
            "type" => "direct",
            "event" => "history",
            "payload" => %{
              "with" => with_agent,
              "messages" => messages,
              "count" => length(messages)
            }
          }}, socket}

        {:error, reason} ->
          {:reply, {:error, %{reason: "history failed: #{inspect(reason)}"}}, socket}
      end
    end
  end

  def handle_in("direct:history", _payload, socket) do
    {:reply, {:error, %{reason: "payload must include \"with\" agent_id"}}, socket}
  end

  # ── replay:request — replay filtered activity events ───────

  def handle_in("replay:request", %{"payload" => payload}, socket) do
    case EventReplay.replay(socket.assigns.fleet_id, payload) do
      {:ok, result} ->
        {:reply, {:ok, %{
          "type" => "replay",
          "event" => "result",
          "payload" => result
        }}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: "replay failed: #{inspect(reason)}"}}, socket}
    end
  end

  def handle_in("replay:request", _payload, socket) do
    handle_in("replay:request", %{"payload" => %{}}, socket)
  end

  # ── Tasks ──────────────────────────────────────────────────

  def handle_in("task:submit", %{"payload" => payload}, socket) do
    fleet_id = socket.assigns.fleet_id

    cond do
      is_nil(payload["prompt"]) or payload["prompt"] == "" ->
        {:reply, {:error, %{
          reason: "missing_prompt",
          message: "Task requires a 'prompt' field.",
          fix: "Add payload.prompt with the work description."
        }}, socket}

      not quota_ok?(socket.assigns.tenant_id, :messages_today) ->
        {:reply, {:error, %{
          reason: "quota_exceeded",
          resource: "messages_today",
          message: "Daily message quota reached.",
          fix: "Wait until quota resets or upgrade your plan."
        }}, socket}

      true ->
        Hub.Quota.increment(socket.assigns.tenant_id, :messages_today)

        attrs = %{
          fleet_id: fleet_id,
          requester_id: socket.assigns.agent_id,
          type: payload["type"] || "general",
          prompt: payload["prompt"],
          capabilities_required: payload["capabilities"] || [],
          priority: payload["priority"],
          ttl_ms: payload["ttl_ms"],
          correlation_id: payload["correlation_id"]
        }

        case Hub.Task.create(attrs) do
          {:ok, task} ->
            # Notify supervisor to attempt immediate routing
            Hub.TaskSupervisor.notify_new_task(fleet_id)

            {:reply, {:ok, %{
              "type" => "task",
              "event" => "submitted",
              "payload" => %{
                "task_id" => task.task_id,
                "status" => "pending"
              }
            }}, socket}
        end
    end
  end

  def handle_in("task:submit", payload, socket) when is_map(payload) do
    handle_in("task:submit", %{"payload" => payload}, socket)
  end

  def handle_in("task:claim", %{"payload" => %{"task_id" => task_id}}, socket) do
    agent_id = socket.assigns.agent_id

    case Hub.Task.get(task_id) do
      {:ok, %{assigned_to: ^agent_id, status: :assigned} = task} ->
        case Hub.Task.start(task_id) do
          {:ok, _updated} ->
            {:reply, {:ok, %{
              "type" => "task",
              "event" => "claimed",
              "payload" => %{
                "task_id" => task_id,
                "prompt" => task.prompt,
                "type" => task.type,
                "priority" => Atom.to_string(task.priority),
                "capabilities_required" => task.capabilities_required,
                "correlation_id" => task.correlation_id
              }
            }}, socket}

          {:error, reason} ->
            {:reply, {:error, %{reason: "claim_failed", message: inspect(reason)}}, socket}
        end

      {:ok, %{assigned_to: other}} when not is_nil(other) ->
        {:reply, {:error, %{
          reason: "not_assigned_to_you",
          message: "Task #{task_id} is assigned to #{other}, not #{agent_id}."
        }}, socket}

      {:ok, %{status: status}} ->
        {:reply, {:error, %{reason: "invalid_status", message: "Task is #{status}, not assigned."}}, socket}

      :not_found ->
        {:reply, {:error, %{reason: "not_found", message: "Task #{task_id} not found."}}, socket}
    end
  end

  def handle_in("task:claim", _payload, socket) do
    {:reply, {:error, %{reason: "payload must include \"task_id\""}}, socket}
  end

  def handle_in("task:result", %{"payload" => payload}, socket) do
    task_id = payload["task_id"]
    agent_id = socket.assigns.agent_id

    case Hub.Task.get(task_id) do
      {:ok, %{assigned_to: ^agent_id, status: status} = _task} when status in [:assigned, :running] ->
        error = payload["error"]

        if error do
          case Hub.Task.fail(task_id, error) do
            {:ok, failed_task} ->
              Hub.TaskSupervisor.push_task_result(failed_task)
              {:reply, {:ok, %{
                "type" => "task",
                "event" => "failed",
                "payload" => %{"task_id" => task_id, "status" => "failed"}
              }}, socket}

            {:error, reason} ->
              {:reply, {:error, %{reason: inspect(reason)}}, socket}
          end
        else
          result = payload["result"] || %{}

          case Hub.Task.complete(task_id, result) do
            {:ok, completed_task} ->
              Hub.TaskSupervisor.push_task_result(completed_task)
              {:reply, {:ok, %{
                "type" => "task",
                "event" => "completed",
                "payload" => %{"task_id" => task_id, "status" => "completed"}
              }}, socket}

            {:error, reason} ->
              {:reply, {:error, %{reason: inspect(reason)}}, socket}
          end
        end

      {:ok, %{assigned_to: other}} when not is_nil(other) ->
        {:reply, {:error, %{reason: "not_assigned_to_you"}}, socket}

      {:ok, %{status: status}} ->
        {:reply, {:error, %{reason: "invalid_status", message: "Task is #{status}."}}, socket}

      :not_found ->
        {:reply, {:error, %{reason: "not_found"}}, socket}
    end
  end

  def handle_in("task:result", payload, socket) when is_map(payload) do
    handle_in("task:result", %{"payload" => payload}, socket)
  end

  def handle_in("task:status", %{"payload" => %{"task_id" => task_id}}, socket) do
    case Hub.Task.get(task_id) do
      {:ok, task} ->
        {:reply, {:ok, %{
          "type" => "task",
          "event" => "status",
          "payload" => Hub.Task.to_map(task)
        }}, socket}

      :not_found ->
        {:reply, {:error, %{reason: "not_found", message: "Task #{task_id} not found."}}, socket}
    end
  end

  def handle_in("task:status", _payload, socket) do
    {:reply, {:error, %{reason: "payload must include \"task_id\""}}, socket}
  end

  # ── Fleet Management (tenant-level) ────────────────────────

  def handle_in("fleet:create", %{"payload" => payload}, socket) do
    tenant_id = socket.assigns.tenant_id

    name = Map.get(payload, "name")
    description = Map.get(payload, "description")

    if is_nil(name) or name == "" do
      {:reply, {:error, %{
        reason: "missing_name",
        message: "Fleet requires a 'name' field.",
        fix: "Add payload.name with the fleet name."
      }}, socket}
    else
      attrs = %{name: name}
      attrs = if description, do: Map.put(attrs, :description, description), else: attrs

      case Hub.Fleets.create_fleet(tenant_id, attrs) do
        {:ok, fleet} ->
          {:reply, {:ok, %{
            "type" => "fleet",
            "event" => "created",
            "payload" => %{
              "id" => fleet.id,
              "name" => fleet.name,
              "description" => fleet.description,
              "tenant_id" => fleet.tenant_id
            }
          }}, socket}

        {:error, changeset} ->
          {:reply, {:error, %{reason: "create_failed", details: inspect(changeset.errors)}}, socket}
      end
    end
  end

  def handle_in("fleet:create", payload, socket) when is_map(payload) do
    handle_in("fleet:create", %{"payload" => payload}, socket)
  end

  def handle_in("fleet:list", _payload, socket) do
    tenant_id = socket.assigns.tenant_id
    fleets = Hub.Fleets.list_fleets(tenant_id)

    {:reply, {:ok, %{
      "type" => "fleet",
      "event" => "list",
      "payload" => %{"fleets" => fleets, "count" => length(fleets)}
    }}, socket}
  end

  def handle_in("fleet:update", %{"payload" => payload}, socket) do
    fleet_id = Map.get(payload, "fleet_id")

    if is_nil(fleet_id) do
      {:reply, {:error, %{reason: "missing_fleet_id", message: "Payload must include 'fleet_id'."}}, socket}
    else
      attrs =
        %{}
        |> maybe_put(:name, Map.get(payload, "name"))
        |> maybe_put(:description, Map.get(payload, "description"))

      case Hub.Fleets.update_fleet(fleet_id, attrs) do
        {:ok, fleet} ->
          {:reply, {:ok, %{
            "type" => "fleet",
            "event" => "updated",
            "payload" => %{
              "id" => fleet.id,
              "name" => fleet.name,
              "description" => fleet.description
            }
          }}, socket}

        {:error, :not_found} ->
          {:reply, {:error, %{reason: "not_found", message: "Fleet not found."}}, socket}

        {:error, changeset} ->
          {:reply, {:error, %{reason: "update_failed", details: inspect(changeset.errors)}}, socket}
      end
    end
  end

  def handle_in("fleet:update", payload, socket) when is_map(payload) do
    handle_in("fleet:update", %{"payload" => payload}, socket)
  end

  def handle_in("fleet:delete", %{"payload" => payload}, socket) do
    fleet_id = Map.get(payload, "fleet_id")

    if is_nil(fleet_id) do
      {:reply, {:error, %{reason: "missing_fleet_id", message: "Payload must include 'fleet_id'."}}, socket}
    else
      case Hub.Fleets.delete_fleet(fleet_id) do
        {:ok, _} ->
          {:reply, {:ok, %{
            "type" => "fleet",
            "event" => "deleted",
            "payload" => %{"fleet_id" => fleet_id}
          }}, socket}

        {:error, :not_found} ->
          {:reply, {:error, %{reason: "not_found", message: "Fleet not found."}}, socket}

        {:error, :has_agents} ->
          {:reply, {:error, %{reason: "has_agents", message: "Cannot delete fleet with agents. Move agents first."}}, socket}

        {:error, :last_fleet} ->
          {:reply, {:error, %{reason: "last_fleet", message: "Cannot delete the last fleet."}}, socket}
      end
    end
  end

  def handle_in("fleet:delete", payload, socket) when is_map(payload) do
    handle_in("fleet:delete", %{"payload" => payload}, socket)
  end

  def handle_in("squad:assign_agent", %{"payload" => payload}, socket) do
    squad_id = Map.get(payload, "squad_id")
    agent_id = Map.get(payload, "agent_id")

    cond do
      is_nil(squad_id) ->
        {:reply, {:error, %{reason: "missing_squad_id"}}, socket}

      is_nil(agent_id) ->
        {:reply, {:error, %{reason: "missing_agent_id"}}, socket}

      true ->
        case Hub.Fleets.assign_agent_to_squad(agent_id, squad_id) do
          {:ok, agent} ->
            {:reply, {:ok, %{
              "type" => "squad",
              "event" => "agent_assigned",
              "payload" => %{
                "agent_id" => agent.agent_id,
                "squad_id" => agent.squad_id,
                "fleet_id" => agent.fleet_id
              }
            }}, socket}

          {:error, reason} ->
            {:reply, {:error, %{reason: to_string(reason), message: "Failed to assign agent to squad."}}, socket}
        end
    end
  end

  def handle_in("squad:assign_agent", payload, socket) when is_map(payload) do
    handle_in("squad:assign_agent", %{"payload" => payload}, socket)
  end

  def handle_in("squad:remove_agent", %{"payload" => payload}, socket) do
    agent_id = Map.get(payload, "agent_id")

    if is_nil(agent_id) do
      {:reply, {:error, %{reason: "missing_agent_id"}}, socket}
    else
      case Hub.Fleets.remove_agent_from_squad(agent_id) do
        {:ok, agent} ->
          {:reply, {:ok, %{
            "type" => "squad",
            "event" => "agent_removed",
            "payload" => %{
              "agent_id" => agent.agent_id,
              "fleet_id" => agent.fleet_id
            }
          }}, socket}

        {:error, reason} ->
          {:reply, {:error, %{reason: to_string(reason)}}, socket}
      end
    end
  end

  def handle_in("squad:remove_agent", payload, socket) when is_map(payload) do
    handle_in("squad:remove_agent", %{"payload" => payload}, socket)
  end

  # ── Groups ──────────────────────────────────────────────────

  def handle_in("group:create", %{"payload" => payload} = raw, socket) do
    idem_key = extract_idempotency_key(raw, socket)

    case check_idempotency(idem_key, socket) do
      {:hit, cached_reply, socket} ->
        {:reply, {:ok, cached_reply}, socket}

      :miss ->
        attrs = %{
          name: payload["name"],
          type: payload["type"] || "squad",
          fleet_id: socket.assigns.fleet_id,
          created_by: socket.assigns.agent_id,
          capabilities: payload["capabilities"] || [],
          settings: payload["settings"] || %{}
        }

        case Hub.Groups.create_group(attrs) do
          {:ok, group} ->
            # Creator auto-joins as owner
            Hub.Groups.join_group(group.group_id, socket.assigns.agent_id, "owner")

            # Subscribe creator to group PubSub topic
            Phoenix.PubSub.subscribe(Hub.PubSub, group_topic(socket, group.group_id))

            # Auto-invite listed agents
            for agent_id <- payload["invite"] || [] do
              Hub.Groups.join_group(group.group_id, agent_id, "member")
              # Notify invited agents
              Phoenix.PubSub.broadcast(
                Hub.PubSub,
                "fleet:#{socket.assigns.fleet_id}:agent:#{agent_id}",
                {:group_invite, %{group_id: group.group_id, name: group.name, type: group.type, invited_by: socket.assigns.agent_id}}
              )
            end

            # Broadcast to fleet
            broadcast!(socket, "group:created", %{
              "type" => "group", "event" => "created",
              "payload" => group_json(group)
            })

            reply = group_json(group)
            store_idempotency(idem_key, reply)
            {:reply, {:ok, reply}, socket}

          {:error, changeset} ->
            {:reply, {:error, %{message: "Failed to create group", details: inspect(changeset.errors)}}, socket}
        end
    end
  end

  def handle_in("group:join", %{"payload" => %{"group_id" => group_id}}, socket) do
    agent_id = socket.assigns.agent_id

    case Hub.Groups.join_group(group_id, agent_id) do
      {:ok, _member} ->
        Phoenix.PubSub.subscribe(Hub.PubSub, group_topic(socket, group_id))

        broadcast!(socket, "group:member_joined", %{
          "type" => "group", "event" => "member_joined",
          "payload" => %{"group_id" => group_id, "agent_id" => agent_id}
        })

        {:reply, {:ok, %{joined: true, group_id: group_id}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{message: "Failed to join group", reason: inspect(reason)}}, socket}
    end
  end

  def handle_in("group:leave", %{"payload" => %{"group_id" => group_id}}, socket) do
    agent_id = socket.assigns.agent_id

    case Hub.Groups.leave_group(group_id, agent_id) do
      {:ok, _} ->
        Phoenix.PubSub.unsubscribe(Hub.PubSub, group_topic(socket, group_id))

        broadcast!(socket, "group:member_left", %{
          "type" => "group", "event" => "member_left",
          "payload" => %{"group_id" => group_id, "agent_id" => agent_id}
        })

        {:reply, {:ok, %{left: true, group_id: group_id}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{message: inspect(reason)}}, socket}
    end
  end

  def handle_in("group:message", %{"payload" => payload}, socket) do
    group_id = payload["group_id"]
    agent_id = socket.assigns.agent_id

    if Hub.Groups.is_member?(group_id, agent_id) do
      # Increment message quota
      Hub.Quota.increment(socket.assigns.tenant_id, :messages)

      envelope = %{
        "type" => "group", "event" => "message",
        "payload" => %{
          "group_id" => group_id,
          "from" => %{"agent_id" => agent_id, "name" => get_agent_name(socket)},
          "message" => payload["message"] || payload,
          "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
        }
      }

      # Broadcast to group topic — only members subscribed will receive
      Phoenix.PubSub.broadcast(Hub.PubSub, group_topic(socket, group_id), {:group_message, envelope})

      {:reply, {:ok, %{sent: true}}, socket}
    else
      {:reply, {:error, %{message: "Not a member of this group"}}, socket}
    end
  end

  def handle_in("group:list", %{"payload" => payload}, socket) do
    opts = [
      status: payload["status"] || "active",
      type: payload["type"]
    ]

    groups = Hub.Groups.list_groups(socket.assigns.fleet_id, opts)
    {:reply, {:ok, %{groups: Enum.map(groups, &group_json/1)}}, socket}
  end

  def handle_in("group:list", _payload, socket) do
    handle_in("group:list", %{"payload" => %{}}, socket)
  end

  def handle_in("group:members", %{"payload" => %{"group_id" => group_id}}, socket) do
    case Hub.Groups.members(group_id) do
      {:ok, members} ->
        {:reply, {:ok, %{members: Enum.map(members, fn m ->
          %{agent_id: m.agent_id, role: m.role, joined_at: m.joined_at}
        end)}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{message: inspect(reason)}}, socket}
    end
  end

  def handle_in("group:dissolve", %{"payload" => payload}, socket) do
    group_id = payload["group_id"]
    result = payload["result"]
    agent_id = socket.assigns.agent_id

    # Only group owner can dissolve
    case Hub.Groups.member_role(group_id, agent_id) do
      {:ok, "owner"} ->
        case Hub.Groups.dissolve_group(group_id, result) do
          {:ok, _group} ->
            broadcast!(socket, "group:dissolved", %{
              "type" => "group", "event" => "dissolved",
              "payload" => %{
                "group_id" => group_id,
                "result" => result,
                "dissolved_by" => agent_id
              }
            })

            {:reply, {:ok, %{dissolved: true, group_id: group_id}}, socket}

          {:error, reason} ->
            {:reply, {:error, %{message: inspect(reason)}}, socket}
        end

      {:ok, _role} ->
        {:reply, {:error, %{reason: "forbidden", message: "Only the group owner can dissolve a group."}}, socket}

      {:error, _} ->
        {:reply, {:error, %{reason: "not_member", message: "You are not a member of this group."}}, socket}
    end
  end

  def handle_in("group:my_groups", _payload, socket) do
    groups = Hub.Groups.groups_for_agent(socket.assigns.agent_id, socket.assigns.fleet_id)
    {:reply, {:ok, %{groups: Enum.map(groups, &group_json/1)}}, socket}
  end

  # Handle incoming group messages from PubSub
  @impl true
  def handle_info({:group_message, envelope}, socket) do
    push(socket, "group:message", envelope)
    {:noreply, socket}
  end

  # Agent migration arrival (from PubSub)
  def handle_info({:agent_arrived, msg}, socket) do
    push(socket, "agent:arrived", msg)
    {:noreply, socket}
  end

  def handle_info({:group_invite, invite}, socket) do
    push(socket, "group:invite", %{
      "type" => "group", "event" => "invite",
      "payload" => invite
    })
    {:noreply, socket}
  end

  # ── Files ────────────────────────────────────────────────────

  def handle_in("file:upload_url", %{"payload" => payload}, socket) do
    filename = Map.get(payload, "filename")
    size = Map.get(payload, "size")
    content_type = Map.get(payload, "content_type", "application/octet-stream")

    cond do
      is_nil(filename) or filename == "" ->
        {:reply, {:error, %{
          reason: "missing_filename",
          message: "Upload requires a 'filename' field.",
          fix: "Add payload.filename with the file name."
        }}, socket}

      is_nil(size) or not is_integer(size) or size <= 0 ->
        {:reply, {:error, %{
          reason: "invalid_size",
          message: "Upload requires a positive integer 'size' (bytes).",
          fix: "Add payload.size with the file size in bytes."
        }}, socket}

      not quota_ok?(socket.assigns.tenant_id, :messages_today) ->
        {:reply, {:error, %{
          reason: "quota_exceeded",
          resource: "messages_today",
          message: "Daily message quota reached.",
          fix: "Wait until quota resets or upgrade your plan."
        }}, socket}

      true ->
        Hub.Quota.increment(socket.assigns.tenant_id, :messages_today)

        case Hub.Files.upload_url(
               filename,
               size,
               content_type,
               socket.assigns.agent_id,
               socket.assigns.tenant_id,
               socket.assigns.fleet_id
             ) do
          {:ok, result} ->
            {:reply, {:ok, %{
              "type" => "file",
              "event" => "upload_url",
              "payload" => result
            }}, socket}

          {:error, reason} ->
            {:reply, {:error, reason}, socket}
        end
    end
  end

  def handle_in("file:upload_url", payload, socket) when is_map(payload) do
    handle_in("file:upload_url", %{"payload" => payload}, socket)
  end

  def handle_in("file:register", %{"payload" => payload}, socket) do
    file_id = Map.get(payload, "file_id")

    if is_nil(file_id) or file_id == "" do
      {:reply, {:error, %{
        reason: "missing_file_id",
        message: "Register requires a 'file_id' field.",
        fix: "Use the file_id returned from file:upload_url."
      }}, socket}
    else
      case Hub.Files.register(file_id, socket.assigns.tenant_id, payload) do
        {:ok, file} ->
          file_data = Hub.Files.file_to_map(file)

          # Broadcast file availability to the fleet
          broadcast!(socket, "file:shared", %{
            "type" => "file",
            "event" => "shared",
            "payload" => Map.merge(file_data, %{
              "from" => %{
                "agent_id" => socket.assigns.agent_id,
                "name" => get_agent_name(socket)
              }
            })
          })

          # Publish to EventBus for durability
          fleet_id = socket.assigns.fleet_id
          bus_topic = "ringforge.#{fleet_id}.activity"
          Task.start(fn ->
            Hub.EventBus.publish(bus_topic, %{
              "kind" => "file_shared",
              "file_id" => file_id,
              "filename" => file.filename,
              "agent_id" => socket.assigns.agent_id,
              "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
            })
          end)

          {:reply, {:ok, %{
            "type" => "file",
            "event" => "registered",
            "payload" => file_data
          }}, socket}

        {:error, reason} ->
          {:reply, {:error, reason}, socket}
      end
    end
  end

  def handle_in("file:register", payload, socket) when is_map(payload) do
    handle_in("file:register", %{"payload" => payload}, socket)
  end

  def handle_in("file:download_url", %{"payload" => %{"file_id" => file_id}}, socket) do
    case Hub.Files.download_url(file_id, socket.assigns.tenant_id) do
      {:ok, result} ->
        {:reply, {:ok, %{
          "type" => "file",
          "event" => "download_url",
          "payload" => result
        }}, socket}

      {:error, reason} ->
        {:reply, {:error, reason}, socket}
    end
  end

  def handle_in("file:download_url", _payload, socket) do
    {:reply, {:error, %{reason: "missing_file_id", message: "Payload must include 'file_id'."}}, socket}
  end

  def handle_in("file:list", %{"payload" => payload}, socket) do
    opts =
      []
      |> maybe_opt(:limit, Map.get(payload, "limit"))
      |> maybe_opt(:offset, Map.get(payload, "offset"))
      |> maybe_opt(:tags, Map.get(payload, "tags"))
      |> maybe_opt(:agent_id, Map.get(payload, "agent_id"))
      |> maybe_opt(:content_type, Map.get(payload, "content_type"))

    {:ok, files} = Hub.Files.list(socket.assigns.fleet_id, socket.assigns.tenant_id, opts)

    {:reply, {:ok, %{
      "type" => "file",
      "event" => "list",
      "payload" => %{"files" => files, "count" => length(files)}
    }}, socket}
  end

  def handle_in("file:list", _payload, socket) do
    handle_in("file:list", %{"payload" => %{}}, socket)
  end

  def handle_in("file:delete", %{"payload" => %{"file_id" => file_id}}, socket) do
    case Hub.Files.delete(file_id, socket.assigns.tenant_id, socket.assigns.agent_id) do
      :ok ->
        # Broadcast file deletion to the fleet
        broadcast!(socket, "file:deleted", %{
          "type" => "file",
          "event" => "deleted",
          "payload" => %{
            "file_id" => file_id,
            "deleted_by" => socket.assigns.agent_id
          }
        })

        {:reply, {:ok, %{deleted: true, file_id: file_id}}, socket}

      {:error, reason} ->
        {:reply, {:error, reason}, socket}
    end
  end

  def handle_in("file:delete", _payload, socket) do
    {:reply, {:error, %{reason: "missing_file_id", message: "Payload must include 'file_id'."}}, socket}
  end

  # ── Agent Profile Handlers ───────────────────────────────────

  def handle_in("agent:update_profile", %{"payload" => payload}, socket) do
    case Auth.find_agent(socket.assigns.agent_id) do
      {:ok, agent} ->
        profile_attrs = %{}
        |> maybe_put(:display_name, Map.get(payload, "display_name"))
        |> maybe_put(:avatar_url, Map.get(payload, "avatar_url"))
        |> maybe_put(:description, Map.get(payload, "description"))
        |> maybe_put(:tags, Map.get(payload, "tags"))
        |> maybe_put(:metadata, Map.get(payload, "metadata"))

        case Auth.update_agent_profile(agent, profile_attrs) do
          {:ok, updated} ->
            profile = Hub.Auth.Agent.to_profile(updated)

            broadcast!(socket, "agent:profile_updated", %{
              "type" => "agent",
              "event" => "profile_updated",
              "payload" => profile
            })

            {:reply, {:ok, %{
              "type" => "agent",
              "event" => "profile_updated",
              "payload" => profile
            }}, socket}

          {:error, changeset} ->
            {:reply, {:error, %{reason: "validation_failed", details: inspect(changeset.errors)}}, socket}
        end

      {:error, _} ->
        {:reply, {:error, %{reason: "agent_not_found"}}, socket}
    end
  end

  def handle_in("agent:update_profile", payload, socket) when is_map(payload) do
    handle_in("agent:update_profile", %{"payload" => payload}, socket)
  end

  def handle_in("agent:get_profile", %{"payload" => payload}, socket) do
    agent_id = Map.get(payload, "agent_id", socket.assigns.agent_id)

    case Auth.get_agent_profile(agent_id) do
      {:ok, profile} ->
        {:reply, {:ok, %{
          "type" => "agent",
          "event" => "profile",
          "payload" => profile
        }}, socket}

      {:error, :not_found} ->
        {:reply, {:error, %{reason: "agent_not_found"}}, socket}
    end
  end

  def handle_in("agent:get_profile", _payload, socket) do
    handle_in("agent:get_profile", %{"payload" => %{}}, socket)
  end

  def handle_in("agent:list_profiles", _payload, socket) do
    {:ok, profiles} = Auth.list_agent_profiles(socket.assigns.fleet_id)

    {:reply, {:ok, %{
      "type" => "agent",
      "event" => "profiles",
      "payload" => %{"agents" => profiles, "count" => length(profiles)}
    }}, socket}
  end

  # ── Agent Migration ────────────────────────────────────────

  def handle_in("agent:migrate", %{"payload" => %{"fleet_id" => target_fleet_id}}, socket) do
    agent_id = socket.assigns.agent_id

    case Auth.migrate_agent(agent_id, target_fleet_id) do
      {:ok, _updated} ->
        # Broadcast departure from current fleet
        broadcast!(socket, "agent:departed", %{
          "type" => "agent",
          "event" => "departed",
          "payload" => %{
            "agent_id" => agent_id,
            "target_fleet_id" => target_fleet_id
          }
        })

        # Notify target fleet of arrival
        Phoenix.PubSub.broadcast(Hub.PubSub, "fleet:#{target_fleet_id}", {:agent_arrived, %{
          "type" => "agent",
          "event" => "arrived",
          "payload" => %{
            "agent_id" => agent_id,
            "from_fleet_id" => socket.assigns.fleet_id
          }
        }})

        {:reply, {:ok, %{
          "type" => "agent",
          "event" => "migrated",
          "payload" => %{
            "agent_id" => agent_id,
            "fleet_id" => target_fleet_id,
            "message" => "Agent migrated. Reconnect to join the new fleet."
          }
        }}, socket}

      {:error, :name_conflict} ->
        {:reply, {:error, %{
          reason: "name_conflict",
          message: "An agent with the same name already exists in the target fleet."
        }}, socket}

      {:error, :cross_tenant} ->
        {:reply, {:error, %{
          reason: "cross_tenant",
          message: "Cannot migrate agents across tenants."
        }}, socket}

      {:error, :same_fleet} ->
        {:reply, {:error, %{
          reason: "same_fleet",
          message: "Agent is already in this fleet."
        }}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  def handle_in("agent:migrate", _payload, socket) do
    {:reply, {:error, %{reason: "payload must include \"fleet_id\""}}, socket}
  end

  # ── auth:rotate_key — rotate Ed25519 public key ─────────────

  def handle_in("auth:rotate_key", %{"payload" => %{"public_key" => pk_base64}}, socket) do
    case Hub.Crypto.decode_public_key(pk_base64) do
      {:ok, pk_bytes} ->
        case Auth.find_agent(socket.assigns.agent_id) do
          {:ok, agent} ->
            case Auth.update_public_key(agent, pk_bytes) do
              {:ok, _updated} ->
                Logger.info("[FleetChannel] Public key rotated for #{socket.assigns.agent_id}")

                {:reply, {:ok, %{
                  "type" => "auth",
                  "event" => "key_rotated",
                  "payload" => %{
                    "agent_id" => socket.assigns.agent_id,
                    "public_key" => pk_base64,
                    "rotated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
                  }
                }}, socket}

              {:error, reason} ->
                {:reply, {:error, %{
                  reason: "key_rotation_failed",
                  message: "Failed to update public key: #{inspect(reason)}"
                }}, socket}
            end

          {:error, _} ->
            {:reply, {:error, %{
              reason: "agent_not_found",
              message: "Could not find agent record."
            }}, socket}
        end

      {:error, _} ->
        {:reply, {:error, %{
          reason: "invalid_public_key",
          message: "Public key must be a valid base64-encoded 32-byte Ed25519 key.",
          fix: "Ensure the key is exactly 32 bytes and base64-encoded."
        }}, socket}
    end
  end

  def handle_in("auth:rotate_key", _payload, socket) do
    {:reply, {:error, %{
      reason: "missing_public_key",
      message: "Payload must include 'public_key' (base64-encoded Ed25519 public key).",
      fix: "Send auth:rotate_key with payload.public_key set to the new base64 key."
    }}, socket}
  end

  # ── Routed Messaging Handlers ─────────────────────────────

  # Replaces raw direct:send with hierarchy-aware routing
  def handle_in("message:send", %{"payload" => %{"to" => to, "body" => body} = payload}, socket) do
    # Handle encrypted messages — decrypt if sealed/encrypted
    body = case Hub.Messaging.Crypto.process_incoming(body, socket.assigns.fleet_id) do
      {:ok, decrypted} when is_map(decrypted) -> decrypted
      {:ok, decrypted} when is_binary(decrypted) -> %{"text" => decrypted}
      _ -> body  # Pass through if not encrypted or decryption fails
    end

    message = %{
      "body" => body,
      "refs" => Map.get(payload, "refs", []),
      "metadata" => Map.get(payload, "metadata", %{}),
      "priority" => Map.get(payload, "priority", "normal"),
      "encrypted" => Map.has_key?(payload, "sealed") || Map.has_key?(payload, "encrypted")
    }

    case Hub.Messaging.Router.route_dm(socket.assigns.fleet_id, socket.assigns.agent_id, to, message) do
      {:ok, _} ->
        {:reply, {:ok, %{"type" => "message", "event" => "sent", "payload" => %{"to" => to}}}, socket}

      {:denied, reason, suggestion} ->
        {:reply, {:error, %{
          "reason" => "messaging_restricted",
          "message" => reason,
          "suggestion" => suggestion
        }}, socket}

      {:limited, retry_after} ->
        {:reply, {:error, %{
          "reason" => "rate_limited",
          "retry_after_ms" => retry_after
        }}, socket}

      {:error, reason} ->
        {:reply, {:error, %{"reason" => to_string(reason)}}, socket}
    end
  end

  def handle_in("message:send", _payload, socket) do
    {:reply, {:error, %{"reason" => "missing_to_or_body"}}, socket}
  end

  # Escalation: route through hierarchy
  def handle_in("message:escalate", %{"payload" => payload}, socket) do
    target_role = Map.get(payload, "target_role")
    attrs = %{
      subject: Map.get(payload, "subject", "Escalation"),
      body: Map.get(payload, "body", ""),
      priority: Map.get(payload, "priority", "normal"),
      context_refs: Map.get(payload, "context_refs", [])
    }

    case Hub.Messaging.Router.route_escalation(
      socket.assigns.fleet_id, socket.assigns.agent_id, target_role, attrs
    ) do
      {:ok, escalation} ->
        {:reply, {:ok, %{
          "type" => "message",
          "event" => "escalated",
          "payload" => %{
            "escalation_id" => escalation.id,
            "routed_to" => escalation.handler_agent,
            "status" => escalation.status
          }
        }}, socket}

      {:denied, reason} ->
        {:reply, {:error, %{"reason" => reason}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{"reason" => to_string(reason)}}, socket}
    end
  end

  def handle_in("message:escalate", _payload, socket) do
    {:reply, {:error, %{"reason" => "missing_payload"}}, socket}
  end

  # Escalation management (for squad leaders)
  def handle_in("escalation:pending", _payload, socket) do
    pending = Hub.Messaging.Escalation.list_pending(
      socket.assigns.fleet_id, socket.assigns.agent_id
    )

    {:reply, {:ok, %{
      "type" => "escalation",
      "event" => "pending",
      "payload" => %{"escalations" => pending}
    }}, socket}
  end

  def handle_in("escalation:forward", %{"payload" => %{"escalation_id" => esc_id, "to" => to}}, socket) do
    case Hub.Messaging.Escalation.forward_escalation(esc_id, socket.assigns.agent_id, to) do
      :ok -> {:reply, {:ok, %{"type" => "escalation", "event" => "forwarded"}}, socket}
      {:error, reason} -> {:reply, {:error, %{"reason" => to_string(reason)}}, socket}
    end
  end

  def handle_in("escalation:handle", %{"payload" => %{"escalation_id" => esc_id, "response" => resp}}, socket) do
    case Hub.Messaging.Escalation.handle_escalation(esc_id, socket.assigns.agent_id, resp) do
      :ok -> {:reply, {:ok, %{"type" => "escalation", "event" => "handled"}}, socket}
      {:error, reason} -> {:reply, {:error, %{"reason" => to_string(reason)}}, socket}
    end
  end

  def handle_in("escalation:reject", %{"payload" => %{"escalation_id" => esc_id, "reason" => reason}}, socket) do
    case Hub.Messaging.Escalation.reject_escalation(esc_id, socket.assigns.agent_id, reason) do
      :ok -> {:reply, {:ok, %{"type" => "escalation", "event" => "rejected"}}, socket}
      {:error, reason} -> {:reply, {:error, %{"reason" => to_string(reason)}}, socket}
    end
  end

  # Broadcast (tier 1+ only)
  def handle_in("message:broadcast", %{"payload" => %{"scope" => scope, "body" => body} = payload}, socket) do
    message = %{
      "body" => body,
      "priority" => Map.get(payload, "priority", "normal"),
      "metadata" => Map.get(payload, "metadata", %{})
    }

    case Hub.Messaging.Router.route_broadcast(socket.assigns.fleet_id, socket.assigns.agent_id, scope, message) do
      {:ok, count} ->
        {:reply, {:ok, %{
          "type" => "message",
          "event" => "broadcasted",
          "payload" => %{"scope" => scope, "delivered_to" => count}
        }}, socket}

      {:denied, reason, _} ->
        {:reply, {:error, %{"reason" => reason}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{"reason" => to_string(reason)}}, socket}
    end
  end

  def handle_in("message:broadcast", _payload, socket) do
    {:reply, {:error, %{"reason" => "missing_scope_or_body"}}, socket}
  end

  # Announcement (one-way, tier 0-1 only)
  def handle_in("message:announce", %{"payload" => %{"scope" => scope} = payload}, socket) do
    attrs = %{
      body: Map.get(payload, "body", ""),
      priority: Map.get(payload, "priority", "normal"),
      metadata: Map.get(payload, "metadata", %{})
    }

    case Hub.Messaging.Announcements.announce(
      socket.assigns.fleet_id, socket.assigns.agent_id, scope, attrs
    ) do
      {:ok, count} ->
        {:reply, {:ok, %{
          "type" => "message",
          "event" => "announced",
          "payload" => %{"scope" => scope, "delivered_to" => count}
        }}, socket}

      {:denied, reason} ->
        {:reply, {:error, %{"reason" => reason}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{"reason" => to_string(reason)}}, socket}
    end
  end

  def handle_in("message:announce", _payload, socket) do
    {:reply, {:error, %{"reason" => "missing_scope"}}, socket}
  end

  # Thread: create
  def handle_in("thread:create", %{"payload" => payload}, socket) do
    attrs = %{
      subject: Map.get(payload, "subject", "Untitled"),
      scope: Map.get(payload, "scope", "dm"),
      participant_ids: Map.get(payload, "participants", [socket.assigns.agent_id]),
      task_id: Map.get(payload, "task_id"),
      fleet_id: socket.assigns.fleet_id,
      squad_id: socket.assigns[:squad_id],
      tenant_id: socket.assigns.tenant_id,
      created_by: socket.assigns.agent_id
    }

    case Hub.Messaging.Threads.create_thread(attrs) do
      {:ok, thread} ->
        # Subscribe creator to thread topic
        Phoenix.PubSub.subscribe(Hub.PubSub, "thread:#{thread.thread_id}")

        {:reply, {:ok, %{
          "type" => "thread",
          "event" => "created",
          "payload" => Hub.Messaging.Threads.thread_to_wire(thread)
        }}, socket}

      {:error, reason} ->
        {:reply, {:error, %{"reason" => to_string(reason)}}, socket}
    end
  end

  def handle_in("thread:create", _payload, socket) do
    {:reply, {:error, %{"reason" => "missing_payload"}}, socket}
  end

  # Thread: reply
  def handle_in("thread:reply", %{"payload" => %{"thread_id" => thread_id, "body" => body} = payload}, socket) do
    message_attrs = %{
      body: body,
      refs: Map.get(payload, "refs", []),
      metadata: Map.get(payload, "metadata", %{})
    }

    case Hub.Messaging.Threads.add_message(thread_id, socket.assigns.agent_id, message_attrs) do
      {:ok, msg} ->
        {:reply, {:ok, %{
          "type" => "thread",
          "event" => "message",
          "payload" => msg
        }}, socket}

      {:error, reason} ->
        {:reply, {:error, %{"reason" => to_string(reason)}}, socket}
    end
  end

  def handle_in("thread:reply", _payload, socket) do
    {:reply, {:error, %{"reason" => "missing_thread_id_or_body"}}, socket}
  end

  # Thread: list messages
  def handle_in("thread:messages", %{"payload" => %{"thread_id" => thread_id} = payload}, socket) do
    opts = [
      limit: Map.get(payload, "limit", 50),
      before: Map.get(payload, "before")
    ]

    messages = Hub.Messaging.Threads.thread_messages(thread_id, opts)

    {:reply, {:ok, %{
      "type" => "thread",
      "event" => "messages",
      "payload" => %{"thread_id" => thread_id, "messages" => messages}
    }}, socket}
  end

  def handle_in("thread:messages", _payload, socket) do
    {:reply, {:error, %{"reason" => "missing_thread_id"}}, socket}
  end

  # Thread: list my threads
  def handle_in("thread:list", _payload, socket) do
    threads = Hub.Messaging.Threads.my_threads(socket.assigns.agent_id, socket.assigns.fleet_id)

    {:reply, {:ok, %{
      "type" => "thread",
      "event" => "list",
      "payload" => %{"threads" => Enum.map(threads, &Hub.Messaging.Threads.thread_to_wire/1)}
    }}, socket}
  end

  # Thread: close
  def handle_in("thread:close", %{"payload" => %{"thread_id" => thread_id} = payload}, socket) do
    reason = Map.get(payload, "reason", "closed by agent")

    case Hub.Messaging.Threads.close_thread(thread_id, socket.assigns.agent_id, reason) do
      {:ok, thread} ->
        {:reply, {:ok, %{
          "type" => "thread",
          "event" => "closed",
          "payload" => Hub.Messaging.Threads.thread_to_wire(thread)
        }}, socket}

      {:error, reason} ->
        {:reply, {:error, %{"reason" => to_string(reason)}}, socket}
    end
  end

  def handle_in("thread:close", _payload, socket) do
    {:reply, {:error, %{"reason" => "missing_thread_id"}}, socket}
  end

  # Business rules management (fleet admin only)
  def handle_in("rules:list", _payload, socket) do
    rules = Hub.Messaging.BusinessRules.load_rules(socket.assigns.fleet_id)
    {:reply, {:ok, %{"type" => "rules", "event" => "list", "payload" => %{"rules" => rules}}}, socket}
  end

  def handle_in("rules:add", %{"payload" => rule}, socket) do
    case Hub.Messaging.BusinessRules.add_rule(socket.assigns.fleet_id, rule) do
      :ok -> {:reply, {:ok, %{"type" => "rules", "event" => "added"}}, socket}
      {:error, reason} -> {:reply, {:error, %{"reason" => to_string(reason)}}, socket}
    end
  end

  def handle_in("rules:remove", %{"payload" => %{"rule_id" => rule_id}}, socket) do
    case Hub.Messaging.BusinessRules.remove_rule(socket.assigns.fleet_id, rule_id) do
      :ok -> {:reply, {:ok, %{"type" => "rules", "event" => "removed"}}, socket}
      {:error, reason} -> {:reply, {:error, %{"reason" => to_string(reason)}}, socket}
    end
  end

  # ── Read Receipt — agent marks a message as read ─────────

  def handle_in("message:read", %{"payload" => %{"message_id" => msg_id}}, socket) do
    # Broadcast read receipt to all fleet agents (sender will pick it up)
    Phoenix.PubSub.broadcast(
      Hub.PubSub,
      "fleet:#{socket.assigns.fleet_id}",
      {:message_read, %{
        "message_id" => msg_id,
        "read_by" => socket.assigns.agent_id,
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
      }}
    )

    {:reply, {:ok, %{"status" => "ack"}}, socket}
  end

  def handle_in("message:read", _payload, socket) do
    {:reply, {:error, %{"reason" => "missing_message_id"}}, socket}
  end

  # ── Typing Indicator ───────────────────────────────────────

  def handle_in("message:typing", %{"payload" => %{"to" => to}}, socket) do
    Phoenix.PubSub.broadcast(
      Hub.PubSub,
      "fleet:#{socket.assigns.fleet_id}:agent:#{to}",
      {:typing_indicator, %{
        "agent_id" => socket.assigns.agent_id,
        "name" => get_agent_name(socket),
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
      }}
    )

    {:noreply, socket}
  end

  def handle_in("message:typing", _payload, socket) do
    {:noreply, socket}
  end

  # ── Message History — retrieve DM history ──────────────────

  def handle_in("message:history", %{"payload" => %{"with" => agent_id} = payload}, socket) do
    limit = Map.get(payload, "limit", 50)

    case Hub.DirectMessage.history(
           socket.assigns.fleet_id,
           socket.assigns.agent_id,
           agent_id,
           limit: limit
         ) do
      {:ok, messages} ->
        {:reply, {:ok, %{
          "type" => "message",
          "event" => "history",
          "payload" => %{
            "with" => agent_id,
            "messages" => messages,
            "count" => length(messages)
          }
        }}, socket}

      {:error, reason} ->
        {:reply, {:error, %{"reason" => "history failed: #{inspect(reason)}"}}, socket}
    end
  end

  def handle_in("message:history", _payload, socket) do
    {:reply, {:error, %{"reason" => "missing_with_agent_id"}}, socket}
  end

  # ── Offline Queue — check queued messages ──────────────────

  def handle_in("message:queued", _payload, socket) do
    queued = Hub.DirectMessage.list_queued(socket.assigns.fleet_id, socket.assigns.agent_id)

    {:reply, {:ok, %{
      "type" => "message",
      "event" => "queued",
      "payload" => %{
        "messages" => queued,
        "count" => length(queued)
      }
    }}, socket}
  end

  # ── Notification Handlers ──────────────────────────────────

  def handle_in("notification:list", _payload, socket) do
    notifications = Hub.Messaging.Notifications.list(
      socket.assigns.fleet_id,
      socket.assigns.agent_id
    )

    {:reply, {:ok, %{
      "type" => "notification",
      "event" => "list",
      "payload" => %{"notifications" => notifications, "count" => length(notifications)}
    }}, socket}
  end

  def handle_in("notification:read", %{"payload" => %{"id" => id}}, socket) do
    Hub.Messaging.Notifications.mark_read(
      socket.assigns.fleet_id,
      socket.assigns.agent_id,
      id
    )

    {:reply, {:ok, %{"status" => "read"}}, socket}
  end

  def handle_in("notification:read", _payload, socket) do
    {:reply, {:error, %{"reason" => "missing_notification_id"}}, socket}
  end

  def handle_in("notification:read_all", _payload, socket) do
    Hub.Messaging.Notifications.mark_all_read(
      socket.assigns.fleet_id,
      socket.assigns.agent_id
    )

    {:reply, {:ok, %{"status" => "all_read"}}, socket}
  end

  def handle_in("notification:unread_count", _payload, socket) do
    count = Hub.Messaging.Notifications.unread_count(
      socket.assigns.fleet_id,
      socket.assigns.agent_id
    )

    {:reply, {:ok, %{"unread_count" => count}}, socket}
  end

  # Thread PubSub notifications
  def handle_info({:thread_message, msg}, socket) do
    push(socket, "thread:message", %{
      "type" => "thread",
      "event" => "message",
      "payload" => msg
    })
    {:noreply, socket}
  end

  def handle_info({:thread_closed, msg}, socket) do
    push(socket, "thread:closed", %{
      "type" => "thread",
      "event" => "closed",
      "payload" => msg
    })
    {:noreply, socket}
  end

  # Escalation notifications (from Hub.Messaging.Escalation via PubSub)
  def handle_info({:message, {:escalation_new, esc}}, socket) do
    push(socket, "escalation:received", %{
      "type" => "escalation", "event" => "new", "payload" => esc
    })
    {:noreply, socket}
  end

  def handle_info({:message, {:escalation_forwarded, esc}}, socket) do
    push(socket, "escalation:update", %{
      "type" => "escalation", "event" => "forwarded", "payload" => esc
    })
    {:noreply, socket}
  end

  def handle_info({:message, {:escalation_handled, esc}}, socket) do
    push(socket, "escalation:update", %{
      "type" => "escalation", "event" => "handled", "payload" => esc
    })
    {:noreply, socket}
  end

  def handle_info({:message, {:escalation_rejected, esc}}, socket) do
    push(socket, "escalation:update", %{
      "type" => "escalation", "event" => "rejected", "payload" => esc
    })
    {:noreply, socket}
  end

  def handle_info({:message, {:escalation_auto_forwarded, esc}}, socket) do
    push(socket, "escalation:update", %{
      "type" => "escalation", "event" => "auto_forwarded", "payload" => esc
    })
    {:noreply, socket}
  end

  # Announcement push
  def handle_info({:announcement, ann}, socket) do
    push(socket, "message:announcement", %{
      "type" => "message",
      "event" => "announcement",
      "payload" => ann
    })
    {:noreply, socket}
  end

  # ── Kanban Handlers ──────────────────────────────────────

  def handle_in("kanban:fleet_board", _payload, socket) do
    board = Hub.Kanban.fleet_board(socket.assigns.fleet_id)
    stats = Hub.Kanban.board_stats(socket.assigns.fleet_id)

    {:reply, {:ok, %{
      "type" => "kanban",
      "event" => "fleet_board",
      "payload" => %{"board" => board, "stats" => stats}
    }}, socket}
  end

  def handle_in("kanban:squad_board", _payload, socket) do
    case socket.assigns[:squad_id] do
      nil ->
        {:reply, {:error, %{"reason" => "no_squad", "message" => "Not assigned to a squad"}}, socket}

      squad_id ->
        board = Hub.Kanban.squad_board(squad_id)
        {:reply, {:ok, %{
          "type" => "kanban",
          "event" => "squad_board",
          "payload" => %{"board" => board}
        }}, socket}
    end
  end

  def handle_in("kanban:my_queue", _payload, socket) do
    queue = Hub.Kanban.agent_queue(socket.assigns.agent_id, socket.assigns.fleet_id)

    {:reply, {:ok, %{
      "type" => "kanban",
      "event" => "my_queue",
      "payload" => %{"tasks" => Enum.map(queue, &kanban_task_to_wire/1)}
    }}, socket}
  end

  def handle_in("kanban:next", _payload, socket) do
    case Hub.Kanban.next_task(socket.assigns.agent_id, socket.assigns.fleet_id) do
      nil ->
        {:reply, {:ok, %{
          "type" => "kanban",
          "event" => "next",
          "payload" => %{"task" => nil, "message" => "No tasks available"}
        }}, socket}

      task ->
        {:reply, {:ok, %{
          "type" => "kanban",
          "event" => "next",
          "payload" => %{"task" => kanban_task_to_wire(task)}
        }}, socket}
    end
  end

  def handle_in("kanban:create", %{"payload" => payload}, socket) do
    attrs =
      payload
      |> Map.put("created_by", socket.assigns.agent_id)
      |> Map.put("tenant_id", socket.assigns.tenant_id)
      |> maybe_put_squad(socket)

    case Hub.Kanban.create_task(socket.assigns.fleet_id, attrs) do
      {:ok, task} ->
        # Broadcast to fleet
        broadcast!(socket, "kanban:task_created", %{
          "type" => "kanban",
          "event" => "task_created",
          "payload" => kanban_task_to_wire(task)
        })

        # Also broadcast to squad if applicable
        if task.squad_id do
          Phoenix.PubSub.broadcast(Hub.PubSub, "squad:#{task.squad_id}", {:kanban_event, %{
            "event" => "task_created",
            "task" => kanban_task_to_wire(task)
          }})
        end

        {:reply, {:ok, %{
          "type" => "kanban",
          "event" => "created",
          "payload" => kanban_task_to_wire(task)
        }}, socket}

      {:error, cs} when is_struct(cs, Ecto.Changeset) ->
        {:reply, {:error, %{"reason" => "validation_error", "errors" => inspect(cs.errors)}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{"reason" => to_string(reason)}}, socket}
    end
  end

  def handle_in("kanban:create", _payload, socket) do
    {:reply, {:error, %{"reason" => "missing_payload"}}, socket}
  end

  def handle_in("kanban:update", %{"payload" => %{"task_id" => task_id} = payload}, socket) do
    attrs = Map.drop(payload, ["task_id"])

    case Hub.Kanban.update_task(task_id, attrs) do
      {:ok, task} ->
        broadcast!(socket, "kanban:task_updated", %{
          "type" => "kanban",
          "event" => "task_updated",
          "payload" => kanban_task_to_wire(task)
        })

        {:reply, {:ok, %{
          "type" => "kanban",
          "event" => "updated",
          "payload" => kanban_task_to_wire(task)
        }}, socket}

      {:error, reason} ->
        {:reply, {:error, %{"reason" => to_string(reason)}}, socket}
    end
  end

  def handle_in("kanban:update", _payload, socket) do
    {:reply, {:error, %{"reason" => "missing_task_id"}}, socket}
  end

  def handle_in("kanban:move", %{"payload" => %{"task_id" => task_id, "lane" => lane}}, socket) do
    reason = Map.get(socket.assigns, :move_reason)

    case Hub.Kanban.move_task(task_id, lane, socket.assigns.agent_id, reason) do
      {:ok, task} ->
        broadcast!(socket, "kanban:task_moved", %{
          "type" => "kanban",
          "event" => "task_moved",
          "payload" => %{
            "task" => kanban_task_to_wire(task),
            "new_lane" => lane,
            "moved_by" => socket.assigns.agent_id
          }
        })

        {:reply, {:ok, %{
          "type" => "kanban",
          "event" => "moved",
          "payload" => kanban_task_to_wire(task)
        }}, socket}

      {:error, reason} ->
        {:reply, {:error, %{"reason" => to_string(reason)}}, socket}
    end
  end

  def handle_in("kanban:move", _payload, socket) do
    {:reply, {:error, %{"reason" => "missing_task_id_or_lane"}}, socket}
  end

  def handle_in("kanban:claim", %{"payload" => %{"task_id" => task_id}}, socket) do
    with {:ok, original_task} <- Hub.Kanban.get_task(task_id),
         {:ok, _updated_task} <- Hub.Kanban.update_task(task_id, %{"assigned_to" => socket.assigns.agent_id}),
         {:ok, task} <- Hub.Kanban.move_task(task_id, "in_progress", socket.assigns.agent_id, "claimed") do
      broadcast!(socket, "kanban:task_claimed", %{
        "type" => "kanban",
        "event" => "task_claimed",
        "payload" => %{
          "task" => kanban_task_to_wire(task),
          "claimed_by" => socket.assigns.agent_id
        }
      })

      # Notify the task creator that it was claimed
      if original_task.created_by && original_task.created_by != socket.assigns.agent_id do
        Task.start(fn ->
          Hub.Messaging.Notifications.notify(
            socket.assigns.fleet_id,
            original_task.created_by,
            :task_assigned,
            %{
              "task_id" => task_id,
              "title" => task.title,
              "claimed_by" => socket.assigns.agent_id
            }
          )
        end)
      end

      {:reply, {:ok, %{
        "type" => "kanban",
        "event" => "claimed",
        "payload" => kanban_task_to_wire(task)
      }}, socket}
    else
      {:error, reason} ->
        {:reply, {:error, %{"reason" => to_string(reason)}}, socket}
    end
  end

  def handle_in("kanban:claim", _payload, socket) do
    {:reply, {:error, %{"reason" => "missing_task_id"}}, socket}
  end

  def handle_in("kanban:progress", %{"payload" => %{"task_id" => task_id} = payload}, socket) do
    progress_text = Map.get(payload, "progress")
    progress_pct = Map.get(payload, "pct")

    attrs =
      %{}
      |> then(fn a -> if progress_text, do: Map.put(a, "progress", progress_text), else: a end)
      |> then(fn a -> if progress_pct, do: Map.put(a, "progress_pct", progress_pct), else: a end)

    case Hub.Kanban.update_task(task_id, attrs) do
      {:ok, task} ->
        broadcast!(socket, "kanban:task_progress", %{
          "type" => "kanban",
          "event" => "task_progress",
          "payload" => %{
            "task_id" => task.task_id,
            "progress" => task.progress,
            "progress_pct" => task.progress_pct,
            "updated_by" => socket.assigns.agent_id
          }
        })

        {:reply, {:ok, %{"type" => "kanban", "event" => "progress_updated"}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{"reason" => to_string(reason)}}, socket}
    end
  end

  def handle_in("kanban:progress", _payload, socket) do
    {:reply, {:error, %{"reason" => "missing_task_id"}}, socket}
  end

  def handle_in("kanban:block", %{"payload" => %{"task_id" => task_id, "reason" => reason}}, socket) do
    case Hub.Kanban.update_task(task_id, %{"blocked_by" => [reason]}) do
      {:ok, task} ->
        broadcast!(socket, "kanban:task_blocked", %{
          "type" => "kanban",
          "event" => "task_blocked",
          "payload" => %{
            "task" => kanban_task_to_wire(task),
            "blocked_by" => socket.assigns.agent_id,
            "reason" => reason
          }
        })

        {:reply, {:ok, %{"type" => "kanban", "event" => "blocked"}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{"reason" => to_string(reason)}}, socket}
    end
  end

  def handle_in("kanban:block", _payload, socket) do
    {:reply, {:error, %{"reason" => "missing_task_id_or_reason"}}, socket}
  end

  def handle_in("kanban:stats", _payload, socket) do
    stats = Hub.Kanban.board_stats(socket.assigns.fleet_id)
    velocity = Hub.Kanban.velocity(socket.assigns.fleet_id, 24)
    cycle = Hub.Kanban.cycle_time(socket.assigns.fleet_id)

    {:reply, {:ok, %{
      "type" => "kanban",
      "event" => "stats",
      "payload" => %{
        "stats" => stats,
        "velocity_24h" => velocity,
        "avg_cycle_time_hours" => cycle
      }
    }}, socket}
  end

  def handle_in("kanban:prioritize", %{"payload" => %{"task_id" => task_id, "priority" => priority}}, socket) do
    case Hub.Kanban.update_task(task_id, %{"priority" => priority}) do
      {:ok, task} ->
        broadcast!(socket, "kanban:task_prioritized", %{
          "type" => "kanban",
          "event" => "task_prioritized",
          "payload" => %{"task_id" => task.task_id, "priority" => priority, "by" => socket.assigns.agent_id}
        })

        {:reply, {:ok, %{"type" => "kanban", "event" => "prioritized"}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{"reason" => to_string(reason)}}, socket}
    end
  end

  def handle_in("kanban:prioritize", _payload, socket) do
    {:reply, {:error, %{"reason" => "missing_task_id_or_priority"}}, socket}
  end

  def handle_in("kanban:history", %{"payload" => %{"task_id" => task_id}}, socket) do
    history = Hub.Kanban.task_history(task_id)

    {:reply, {:ok, %{
      "type" => "kanban",
      "event" => "history",
      "payload" => %{"task_id" => task_id, "history" => history}
    }}, socket}
  end

  def handle_in("kanban:history", _payload, socket) do
    {:reply, {:error, %{"reason" => "missing_task_id"}}, socket}
  end

  # Kanban event from PubSub (squad-scoped)
  def handle_info({:kanban_event, event}, socket) do
    push(socket, "kanban:event", %{
      "type" => "kanban",
      "event" => event["event"],
      "payload" => event
    })

    {:noreply, socket}
  end

  # ── Role & Context Injection Handlers ─────────────────────

  def handle_in("role:list", _payload, socket) do
    roles = Hub.Roles.list_roles(socket.assigns.tenant_id)
    {:reply, {:ok, %{
      "type" => "role",
      "event" => "list",
      "payload" => %{"roles" => Enum.map(roles, &Hub.Roles.to_wire/1)}
    }}, socket}
  end

  def handle_in("role:info", _payload, socket) do
    case Hub.Roles.agent_role_context(socket.assigns.agent_id) do
      nil ->
        {:reply, {:ok, %{
          "type" => "role",
          "event" => "info",
          "payload" => %{"role" => nil, "message" => "No role assigned"}
        }}, socket}

      ctx ->
        {:reply, {:ok, %{
          "type" => "role",
          "event" => "info",
          "payload" => %{"role" => ctx}
        }}, socket}
    end
  end

  def handle_in("role:context", _payload, socket) do
    agent = fetch_agent(socket)

    case Hub.ContextInjection.build_role_context(agent) do
      nil ->
        {:reply, {:ok, %{
          "type" => "role",
          "event" => "context",
          "payload" => %{"context" => nil, "message" => "No role assigned"}
        }}, socket}

      role_ctx ->
        {:reply, {:ok, %{
          "type" => "role",
          "event" => "context",
          "payload" => role_ctx
        }}, socket}
    end
  end

  def handle_in("role:assign", %{"payload" => %{"slug" => slug}}, socket) do
    case Hub.Roles.assign_role_by_slug(socket.assigns.agent_id, slug, socket.assigns.tenant_id) do
      {:ok, agent} ->
        # Push new role context immediately
        case Hub.ContextInjection.build_role_context(agent) do
          nil -> :ok
          ctx -> push(socket, "role:context", %{"type" => "role", "event" => "context", "payload" => ctx})
        end

        {:reply, {:ok, %{
          "type" => "role",
          "event" => "assigned",
          "payload" => %{"slug" => slug, "agent_id" => socket.assigns.agent_id}
        }}, socket}

      {:error, reason} ->
        {:reply, {:error, %{"reason" => to_string(reason)}}, socket}
    end
  end

  def handle_in("role:assign", %{"payload" => %{"agent_id" => target, "slug" => slug}}, socket) do
    # Squad leaders can assign roles to squad members
    with squad_id when not is_nil(squad_id) <- socket.assigns[:squad_id],
         {:ok, role} <- Hub.Groups.member_role(get_group_id_for_squad(squad_id), socket.assigns.agent_id),
         true <- role in ["admin", "owner", "leader"] do
      case Hub.Roles.assign_role_by_slug(target, slug, socket.assigns.tenant_id) do
        {:ok, _} ->
          # Notify target agent
          Phoenix.PubSub.broadcast(Hub.PubSub,
            "fleet:#{socket.assigns.fleet_id}:agent:#{target}",
            {:role_assigned, %{"slug" => slug, "assigned_by" => socket.assigns.agent_id}}
          )

          {:reply, {:ok, %{
            "type" => "role",
            "event" => "assigned",
            "payload" => %{"slug" => slug, "agent_id" => target}
          }}, socket}

        {:error, reason} ->
          {:reply, {:error, %{"reason" => to_string(reason)}}, socket}
      end
    else
      _ -> {:reply, {:error, %{"reason" => "unauthorized", "message" => "Only squad leaders can assign roles to others"}}, socket}
    end
  end

  def handle_in("role:assign", _payload, socket) do
    {:reply, {:error, %{"reason" => "missing_slug", "message" => "Provide slug or {agent_id, slug}"}}, socket}
  end

  def handle_in("agent:calibrate", _payload, socket) do
    challenge = Hub.ContextInjection.calibration_challenge()
    socket = assign(socket, :calibration_challenge_id, challenge["challenge_id"])

    {:reply, {:ok, %{
      "type" => "calibration",
      "event" => "challenge",
      "payload" => challenge
    }}, socket}
  end

  def handle_in("agent:calibrate_response", %{"payload" => %{"response" => response}}, socket) do
    result = Hub.ContextInjection.evaluate_calibration(response)

    # Store tier on agent
    agent = fetch_agent(socket)
    if agent do
      Hub.Auth.Agent.changeset(agent, %{
        context_tier: result.tier,
        tier_calibrated_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Hub.Repo.update()
    end

    {:reply, {:ok, %{
      "type" => "calibration",
      "event" => "result",
      "payload" => %{
        "tier" => result.tier,
        "score" => result.score,
        "max_score" => result.max_score
      }
    }}, socket}
  end

  def handle_in("agent:calibrate_response", _payload, socket) do
    {:reply, {:error, %{"reason" => "missing_response"}}, socket}
  end

  # Notify agent when their role is assigned by a leader
  def handle_info({:role_assigned, msg}, socket) do
    case Hub.ContextInjection.build_role_context(fetch_agent(socket)) do
      nil -> :ok
      ctx -> push(socket, "role:context", %{"type" => "role", "event" => "context", "payload" => ctx})
    end

    push(socket, "role:assigned", %{
      "type" => "role",
      "event" => "assigned",
      "payload" => msg
    })

    {:noreply, socket}
  end

  # ── Artifact Handlers ──────────────────────────────────────

  def handle_in("artifact:put", %{"payload" => payload}, socket) do
    content_b64 = Map.get(payload, "content", "")

    case Base.decode64(content_b64) do
      {:ok, content} ->
        attrs = %{
          "task_id" => payload["task_id"],
          "filename" => payload["filename"],
          "path" => payload["path"],
          "content" => content,
          "language" => payload["language"],
          "description" => payload["description"],
          "tags" => payload["tags"] || [],
          "squad_id" => socket.assigns[:squad_id]
        }

        case Hub.Artifacts.put_artifact(
               socket.assigns.fleet_id,
               socket.assigns.agent_id,
               attrs
             ) do
          {:ok, artifact} ->
            wire = Hub.Artifacts.to_wire(artifact)
            event = if artifact.version == 1, do: "artifact:created", else: "artifact:updated"

            broadcast!(socket, event, %{
              "type" => "artifact",
              "event" => event,
              "payload" => wire
            })

            {:reply, {:ok, %{
              "type" => "artifact",
              "event" => event,
              "payload" => wire
            }}, socket}

          {:error, reason} ->
            {:reply, {:error, %{reason: "artifact_put_failed", details: inspect(reason)}}, socket}
        end

      :error ->
        {:reply, {:error, %{reason: "invalid_base64", message: "Content must be base64 encoded."}}, socket}
    end
  end

  def handle_in("artifact:put", payload, socket) when is_map(payload) do
    handle_in("artifact:put", %{"payload" => payload}, socket)
  end

  def handle_in("artifact:get", %{"payload" => %{"artifact_id" => artifact_id}}, socket) do
    with {:ok, artifact} <- Hub.Artifacts.get_artifact(artifact_id),
         {:ok, content} <- Hub.Artifacts.get_artifact_content(artifact_id) do
      wire = Hub.Artifacts.to_wire(artifact)

      {:reply, {:ok, %{
        "type" => "artifact",
        "event" => "get",
        "payload" => Map.put(wire, "content", Base.encode64(content))
      }}, socket}
    else
      {:error, :not_found} ->
        {:reply, {:error, %{reason: "not_found", message: "Artifact not found."}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: "artifact_get_failed", details: inspect(reason)}}, socket}
    end
  end

  def handle_in("artifact:get", %{"payload" => _}, socket) do
    {:reply, {:error, %{reason: "missing_artifact_id", message: "Provide payload.artifact_id."}}, socket}
  end

  def handle_in("artifact:list", %{"payload" => payload}, socket) do
    opts =
      payload
      |> Map.take(["task_id", "status", "created_by", "language", "tags", "limit"])

    artifacts = Hub.Artifacts.list_artifacts(socket.assigns.fleet_id, opts)

    {:reply, {:ok, %{
      "type" => "artifact",
      "event" => "list",
      "payload" => %{
        "artifacts" => Enum.map(artifacts, &Hub.Artifacts.to_wire/1),
        "count" => length(artifacts)
      }
    }}, socket}
  end

  def handle_in("artifact:list", _payload, socket) do
    handle_in("artifact:list", %{"payload" => %{}}, socket)
  end

  def handle_in("artifact:review", %{"payload" => payload}, socket) do
    artifact_id = payload["artifact_id"]
    agent_id = socket.assigns.agent_id

    # Check reviewer permissions: tech-lead, squad-leader, or PM roles
    role_ctx = Hub.Roles.agent_role_context(agent_id)
    role_slug = if role_ctx, do: role_ctx[:role_slug], else: nil

    squad_leader? =
      case socket.assigns[:squad_id] do
        nil -> false
        squad_id ->
          case Hub.Repo.get(Hub.Groups.Group, squad_id) do
            nil -> false
            group ->
              case Hub.Groups.member_role(group.group_id, agent_id) do
                {:ok, role} when role in ["admin", "owner"] -> true
                _ -> false
              end
          end
      end

    can_review? = squad_leader? or role_slug in ["tech-lead", "pm", "project-manager", "engineering-lead", "cto"]

    if can_review? do
      case Hub.Artifacts.review_artifact(artifact_id, agent_id, payload) do
        {:ok, artifact} ->
          wire = Hub.Artifacts.to_wire(artifact)

          broadcast!(socket, "artifact:reviewed", %{
            "type" => "artifact",
            "event" => "reviewed",
            "payload" => wire
          })

          {:reply, {:ok, %{
            "type" => "artifact",
            "event" => "reviewed",
            "payload" => wire
          }}, socket}

        {:error, :not_found} ->
          {:reply, {:error, %{reason: "not_found", message: "Artifact not found."}}, socket}

        {:error, reason} ->
          {:reply, {:error, %{reason: "review_failed", details: inspect(reason)}}, socket}
      end
    else
      {:reply, {:error, %{
        reason: "insufficient_permissions",
        message: "Only tech-leads, squad leaders, and PMs can review artifacts."
      }}, socket}
    end
  end

  def handle_in("artifact:review", payload, socket) when is_map(payload) do
    handle_in("artifact:review", %{"payload" => payload}, socket)
  end

  def handle_in("artifact:diff", %{"payload" => %{"artifact_id" => id, "v1" => v1, "v2" => v2}}, socket) do
    case Hub.Artifacts.diff_versions(id, v1, v2) do
      {:ok, diff} ->
        {:reply, {:ok, %{
          "type" => "artifact",
          "event" => "diff",
          "payload" => %{
            "artifact_id" => id,
            "v1" => v1,
            "v2" => v2,
            "diff" => diff
          }
        }}, socket}

      {:error, :not_found} ->
        {:reply, {:error, %{reason: "not_found", message: "Version not found."}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: "diff_failed", details: inspect(reason)}}, socket}
    end
  end

  def handle_in("artifact:diff", %{"payload" => _}, socket) do
    {:reply, {:error, %{reason: "missing_params", message: "Provide artifact_id, v1, and v2."}}, socket}
  end

  def handle_in("artifact:history", %{"payload" => %{"artifact_id" => id}}, socket) do
    versions = Hub.Artifacts.artifact_history(id)

    {:reply, {:ok, %{
      "type" => "artifact",
      "event" => "history",
      "payload" => %{
        "artifact_id" => id,
        "versions" => Enum.map(versions, &Hub.Artifacts.version_to_wire/1),
        "count" => length(versions)
      }
    }}, socket}
  end

  def handle_in("artifact:history", %{"payload" => _}, socket) do
    {:reply, {:error, %{reason: "missing_artifact_id", message: "Provide payload.artifact_id."}}, socket}
  end

  def handle_in("artifact:search", %{"payload" => %{"query" => query}}, socket) do
    artifacts = Hub.Artifacts.search_artifacts(socket.assigns.fleet_id, query)

    {:reply, {:ok, %{
      "type" => "artifact",
      "event" => "search",
      "payload" => %{
        "artifacts" => Enum.map(artifacts, &Hub.Artifacts.to_wire/1),
        "count" => length(artifacts),
        "query" => query
      }
    }}, socket}
  end

  def handle_in("artifact:search", %{"payload" => _}, socket) do
    {:reply, {:error, %{reason: "missing_query", message: "Provide payload.query."}}, socket}
  end

  # ── Device Handlers (IoT/Domotic) ────────────────────────

  def handle_in("device:register", %{"payload" => payload}, socket) do
    attrs = %{
      name: payload["name"],
      device_type: payload["device_type"] || "sensor",
      protocol: payload["protocol"] || "mqtt",
      topic: payload["topic"],
      metadata: payload["metadata"] || %{}
    }

    case Hub.Devices.register_device(
           socket.assigns.tenant_id,
           socket.assigns.fleet_id,
           attrs
         ) do
      {:ok, device} ->
        broadcast!(socket, "device:registered", %{
          "type" => "device",
          "event" => "registered",
          "payload" => %{
            "device_id" => device.id,
            "name" => device.name,
            "device_type" => device.device_type,
            "protocol" => device.protocol,
            "topic" => device.topic
          }
        })

        {:reply, {:ok, %{device_id: device.id, name: device.name}}, socket}

      {:error, changeset} ->
        {:reply, {:error, %{reason: "registration_failed", details: inspect(changeset.errors)}}, socket}
    end
  end

  def handle_in("device:register", payload, socket) when is_map(payload) do
    handle_in("device:register", %{"payload" => payload}, socket)
  end

  def handle_in("device:reading", %{"payload" => payload}, socket) do
    device_id = payload["device_id"]
    value = payload["value"]

    if is_nil(device_id) do
      {:reply, {:error, %{reason: "missing_device_id"}}, socket}
    else
      case Hub.Devices.update_reading(device_id, value, socket.assigns.fleet_id) do
        {:ok, _device} ->
          {:reply, {:ok, %{status: "updated"}}, socket}

        {:error, reason} ->
          {:reply, {:error, %{reason: inspect(reason)}}, socket}
      end
    end
  end

  def handle_in("device:reading", payload, socket) when is_map(payload) do
    handle_in("device:reading", %{"payload" => payload}, socket)
  end

  def handle_in("device:command", %{"payload" => payload}, socket) do
    device_id = payload["device_id"]
    command = payload["command"]

    if is_nil(device_id) or is_nil(command) do
      {:reply, {:error, %{reason: "missing device_id or command"}}, socket}
    else
      case Hub.Devices.send_command(device_id, command) do
        {:ok, status} ->
          {:reply, {:ok, %{status: to_string(status)}}, socket}

        {:error, reason} ->
          {:reply, {:error, %{reason: inspect(reason)}}, socket}
      end
    end
  end

  def handle_in("device:command", payload, socket) when is_map(payload) do
    handle_in("device:command", %{"payload" => payload}, socket)
  end

  def handle_in("device:list", _payload, socket) do
    devices = Hub.Devices.list_devices(socket.assigns.fleet_id)

    device_list =
      Enum.map(devices, fn d ->
        %{
          "device_id" => d.id,
          "name" => d.name,
          "device_type" => d.device_type,
          "protocol" => d.protocol,
          "topic" => d.topic,
          "online" => d.online,
          "last_value" => d.last_value,
          "last_seen_at" =>
            if(d.last_seen_at, do: DateTime.to_iso8601(d.last_seen_at))
        }
      end)

    {:reply, {:ok, %{
      "type" => "device",
      "event" => "list",
      "payload" => %{"devices" => device_list, "count" => length(device_list)}
    }}, socket}
  end

  # ── Squad Handlers ─────────────────────────────────────────

  # squad:roster — returns only agents in caller's squad
  def handle_in("squad:roster", _payload, socket) do
    case socket.assigns[:squad_id] do
      nil ->
        {:reply, {:error, %{reason: "no_squad", message: "You are not assigned to a squad."}}, socket}

      squad_id ->
        # Get all agents in this squad from the fleet presence list
        topic = "fleet:#{socket.assigns.fleet_id}"
        all_presence = FleetPresence.list(topic)

        # Look up which agent_ids are in this squad
        squad_agent_ids = get_squad_agent_ids(squad_id)

        squad_roster =
          all_presence
          |> Enum.filter(fn {agent_id, _} -> agent_id in squad_agent_ids end)
          |> Enum.flat_map(fn {agent_id, %{metas: metas}} ->
            Enum.map(metas, fn meta -> presence_payload(agent_id, meta) end)
          end)

        {:reply, {:ok, %{
          "type" => "squad",
          "event" => "roster",
          "payload" => %{"agents" => squad_roster, "squad_id" => squad_id}
        }}, socket}
    end
  end

  # squad:memory:set — stores with key smem:{squad_id}:{key}
  def handle_in("squad:memory:set", %{"payload" => payload}, socket) do
    case require_squad(socket) do
      {:error, reply} ->
        {:reply, {:error, reply}, socket}

      {:ok, squad_id} ->
        key = Map.get(payload, "key")

        cond do
          is_nil(key) or key == "" ->
            {:reply, {:error, %{
              reason: "missing_key",
              message: "Squad memory entries require a 'key' field."
            }}, socket}

          not quota_ok?(socket.assigns.tenant_id, :memory_entries) ->
            {:reply, {:error, %{
              reason: "quota_exceeded",
              resource: "memory_entries",
              message: "Memory entry quota reached."
            }}, socket}

          true ->
            Hub.Quota.increment(socket.assigns.tenant_id, :memory_entries)
            params = Map.put(payload, "author", socket.assigns.agent_id)

            case Hub.SquadMemory.set(squad_id, key, params) do
              {:ok, entry} ->
                {:reply, {:ok, %{
                  "type" => "squad",
                  "event" => "memory:set",
                  "payload" => %{id: entry["id"], key: entry["key"], squad_id: squad_id}
                }}, socket}
            end
        end
    end
  end

  def handle_in("squad:memory:set", payload, socket) when is_map(payload) do
    handle_in("squad:memory:set", %{"payload" => payload}, socket)
  end

  # squad:memory:get — reads squad-scoped memory
  def handle_in("squad:memory:get", %{"payload" => %{"key" => key}}, socket) do
    case require_squad(socket) do
      {:error, reply} ->
        {:reply, {:error, reply}, socket}

      {:ok, squad_id} ->
        case Hub.SquadMemory.get(squad_id, key) do
          {:ok, entry} ->
            {:reply, {:ok, %{type: "squad", event: "memory:entry", payload: entry}}, socket}

          :not_found ->
            {:reply, {:error, %{reason: "not_found"}}, socket}
        end
    end
  end

  def handle_in("squad:memory:get", _payload, socket) do
    {:reply, {:error, %{reason: "payload must include \"key\""}}, socket}
  end

  # squad:memory:list — lists squad memory keys
  def handle_in("squad:memory:list", %{"payload" => payload}, socket) do
    case require_squad(socket) do
      {:error, reply} ->
        {:reply, {:error, reply}, socket}

      {:ok, squad_id} ->
        opts =
          []
          |> maybe_opt(:limit, Map.get(payload, "limit"))
          |> maybe_opt(:offset, Map.get(payload, "offset"))
          |> maybe_opt(:tags, Map.get(payload, "tags"))
          |> maybe_opt(:author, Map.get(payload, "author"))

        {:ok, entries} = Hub.SquadMemory.list(squad_id, opts)

        {:reply, {:ok, %{
          type: "squad",
          event: "memory:list",
          payload: %{entries: entries, count: length(entries), squad_id: squad_id}
        }}, socket}
    end
  end

  def handle_in("squad:memory:list", _payload, socket) do
    handle_in("squad:memory:list", %{"payload" => %{}}, socket)
  end

  # squad:memory:delete — deletes squad memory entry
  def handle_in("squad:memory:delete", %{"payload" => %{"key" => key}}, socket) do
    case require_squad(socket) do
      {:error, reply} ->
        {:reply, {:error, reply}, socket}

      {:ok, squad_id} ->
        case Hub.SquadMemory.delete(squad_id, key) do
          :ok ->
            {:reply, {:ok, %{deleted: true, squad_id: squad_id}}, socket}

          :not_found ->
            {:reply, {:error, %{reason: "not_found"}}, socket}
        end
    end
  end

  def handle_in("squad:memory:delete", _payload, socket) do
    {:reply, {:error, %{reason: "payload must include \"key\""}}, socket}
  end

  # squad:activity:broadcast — broadcasts activity only to squad members
  def handle_in("squad:activity:broadcast", %{"payload" => payload}, socket) do
    case require_squad(socket) do
      {:error, reply} ->
        {:reply, {:error, reply}, socket}

      {:ok, squad_id} ->
        kind = Map.get(payload, "kind")

        cond do
          kind not in @valid_activity_kinds ->
            {:reply, {:error, %{
              reason: "invalid_activity_kind",
              message: "Activity kind '#{kind}' is not valid. Must be one of: #{Enum.join(@valid_activity_kinds, ", ")}."
            }}, socket}

          not quota_ok?(socket.assigns.tenant_id, :messages_today) ->
            {:reply, {:error, %{
              reason: "quota_exceeded",
              resource: "messages_today",
              message: "Daily message quota reached."
            }}, socket}

          true ->
            Hub.Quota.increment(socket.assigns.tenant_id, :messages_today)
            event_id = "evt_" <> gen_uuid()

            event = %{
              "event_id" => event_id,
              "from" => %{
                "agent_id" => socket.assigns.agent_id,
                "name" => get_agent_name(socket)
              },
              "kind" => kind,
              "description" => Map.get(payload, "description", ""),
              "tags" => Map.get(payload, "tags", []),
              "data" => Map.get(payload, "data", %{}),
              "squad_id" => squad_id,
              "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
            }

            broadcast_msg = %{
              "type" => "squad",
              "event" => "activity:broadcast",
              "payload" => event
            }

            # Broadcast only to squad topic
            Phoenix.PubSub.broadcast(Hub.PubSub, "squad:#{squad_id}", {:squad_activity, broadcast_msg})

            # Persist to EventBus with squad_id in metadata for filtering
            fleet_id = socket.assigns.fleet_id
            bus_topic = "ringforge.#{fleet_id}.activity"

            Task.start(fn ->
              Hub.EventBus.publish(bus_topic, Map.put(event, "squad_id", squad_id))
            end)

            {:reply, {:ok, %{event_id: event_id, squad_id: squad_id}}, socket}
        end
    end
  end

  def handle_in("squad:activity:broadcast", payload, socket) when is_map(payload) do
    handle_in("squad:activity:broadcast", %{"payload" => payload}, socket)
  end

  # squad:activity:history — returns activities filtered to squad
  def handle_in("squad:activity:history", %{"payload" => payload}, socket) do
    case require_squad(socket) do
      {:error, reply} ->
        {:reply, {:error, reply}, socket}

      {:ok, squad_id} ->
        fleet_id = socket.assigns.fleet_id
        bus_topic = "ringforge.#{fleet_id}.activity"
        limit = Map.get(payload, "limit", 50)

        case Hub.EventBus.replay(bus_topic, limit: limit) do
          {:ok, events} ->
            # Filter to only events with matching squad_id
            squad_events = Enum.filter(events, fn evt ->
              Map.get(evt, "squad_id") == squad_id
            end)

            {:reply, {:ok, %{
              "type" => "squad",
              "event" => "activity:history",
              "payload" => %{
                "events" => squad_events,
                "count" => length(squad_events),
                "squad_id" => squad_id
              }
            }}, socket}

          {:error, reason} ->
            {:reply, {:error, %{reason: "replay failed: #{inspect(reason)}"}}, socket}
        end
    end
  end

  def handle_in("squad:activity:history", _payload, socket) do
    handle_in("squad:activity:history", %{"payload" => %{}}, socket)
  end

  # squad:task:assign — leader assigns a task to a squad member
  def handle_in("squad:task:assign", %{"payload" => payload}, socket) do
    case require_squad_leader(socket) do
      {:error, reply} ->
        {:reply, {:error, reply}, socket}

      {:ok, squad_id} ->
        target_agent_id = Map.get(payload, "agent_id")
        description = Map.get(payload, "description")

        cond do
          is_nil(target_agent_id) or target_agent_id == "" ->
            {:reply, {:error, %{reason: "missing_agent_id", message: "Must specify target agent_id."}}, socket}

          is_nil(description) or description == "" ->
            {:reply, {:error, %{reason: "missing_description", message: "Must specify task description."}}, socket}

          true ->
            # Verify target agent is in the same squad
            squad_agent_ids = get_squad_agent_ids(squad_id)

            if target_agent_id not in squad_agent_ids do
              {:reply, {:error, %{
                reason: "not_in_squad",
                message: "Agent #{target_agent_id} is not in this squad."
              }}, socket}
            else
              task_id = "stask_" <> gen_uuid()

              task_msg = %{
                "type" => "squad",
                "event" => "task:assigned",
                "payload" => %{
                  "task_id" => task_id,
                  "assigned_by" => socket.assigns.agent_id,
                  "assigned_to" => target_agent_id,
                  "description" => description,
                  "data" => Map.get(payload, "data", %{}),
                  "squad_id" => squad_id,
                  "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
                }
              }

              # Deliver to the target agent via their agent-specific PubSub topic
              Phoenix.PubSub.broadcast(
                Hub.PubSub,
                "fleet:#{socket.assigns.fleet_id}:agent:#{target_agent_id}",
                {:squad_task_assigned, task_msg}
              )

              # Also broadcast to squad topic so everyone sees the assignment
              Phoenix.PubSub.broadcast(Hub.PubSub, "squad:#{squad_id}", {:squad_activity, %{
                "type" => "squad",
                "event" => "activity:broadcast",
                "payload" => %{
                  "event_id" => task_id,
                  "from" => %{
                    "agent_id" => socket.assigns.agent_id,
                    "name" => get_agent_name(socket)
                  },
                  "kind" => "task_started",
                  "description" => "Task assigned to #{target_agent_id}: #{description}",
                  "squad_id" => squad_id,
                  "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
                }
              }})

              {:reply, {:ok, %{
                "type" => "squad",
                "event" => "task:assigned",
                "payload" => %{task_id: task_id, assigned_to: target_agent_id}
              }}, socket}
            end
        end
    end
  end

  def handle_in("squad:task:assign", payload, socket) when is_map(payload) do
    handle_in("squad:task:assign", %{"payload" => payload}, socket)
  end

  # squad:kick — leader removes an agent from the squad
  def handle_in("squad:kick", %{"payload" => payload}, socket) do
    case require_squad_leader(socket) do
      {:error, reply} ->
        {:reply, {:error, reply}, socket}

      {:ok, squad_id} ->
        target_agent_id = Map.get(payload, "agent_id")

        cond do
          is_nil(target_agent_id) or target_agent_id == "" ->
            {:reply, {:error, %{reason: "missing_agent_id", message: "Must specify agent_id to kick."}}, socket}

          target_agent_id == socket.assigns.agent_id ->
            {:reply, {:error, %{reason: "cannot_kick_self", message: "Cannot kick yourself from the squad."}}, socket}

          true ->
            case Hub.Fleets.remove_agent_from_squad(target_agent_id) do
              {:ok, _agent} ->
                # Broadcast to squad that agent was kicked
                Phoenix.PubSub.broadcast(Hub.PubSub, "squad:#{squad_id}", {:squad_presence, %{
                  "type" => "squad",
                  "event" => "presence",
                  "payload" => %{
                    "agent_id" => target_agent_id,
                    "action" => "kicked",
                    "kicked_by" => socket.assigns.agent_id
                  }
                }})

                {:reply, {:ok, %{
                  "type" => "squad",
                  "event" => "kicked",
                  "payload" => %{
                    "agent_id" => target_agent_id,
                    "squad_id" => squad_id,
                    "kicked_by" => socket.assigns.agent_id
                  }
                }}, socket}

              {:error, reason} ->
                {:reply, {:error, %{reason: to_string(reason)}}, socket}
            end
        end
    end
  end

  def handle_in("squad:kick", payload, socket) when is_map(payload) do
    handle_in("squad:kick", %{"payload" => payload}, socket)
  end

  # ── Terminate — cleanup on disconnect ──────────────────────

  @impl true
  def terminate(reason, socket) do
    agent_id = socket.assigns.agent_id

    # Decrement connected_agents quota
    Hub.Quota.decrement(socket.assigns.tenant_id, :connected_agents)

    # Emit telemetry
    Hub.Telemetry.execute([:hub, :channel, :leave], %{count: 1}, %{
      agent_id: agent_id,
      fleet_id: socket.assigns.fleet_id,
      reason: inspect(reason)
    })

    # Broadcast left event
    broadcast!(socket, "presence:left", %{
      "type" => "presence",
      "event" => "left",
      "payload" => %{
        "agent_id" => agent_id
      }
    })

    # Broadcast squad leave if agent was in a squad
    if squad_id = socket.assigns[:squad_id] do
      Phoenix.PubSub.broadcast(Hub.PubSub, "squad:#{squad_id}", {:squad_presence, %{
        "type" => "squad",
        "event" => "presence",
        "payload" => %{
          "agent_id" => agent_id,
          "action" => "left"
        }
      }})
    end

    # Update last_seen_at in DB and end session
    case Auth.find_agent(agent_id) do
      {:ok, agent} ->
        Auth.touch_agent(agent)

        # End active session — find the most recent open session for this agent
        Task.start(fn ->
          import Ecto.Query
          case Hub.Repo.one(
            from s in Hub.Auth.AgentSession,
              where: s.agent_id == ^agent.id and is_nil(s.disconnected_at),
              order_by: [desc: s.connected_at],
              limit: 1,
              select: s.id
          ) do
            nil -> :ok
            session_id ->
              disconnect_reason = case reason do
                {:shutdown, :closed} -> "closed"
                {:shutdown, r} -> "shutdown:#{inspect(r)}"
                :normal -> "normal"
                _ -> inspect(reason)
              end
              Auth.end_agent_session(session_id, disconnect_reason)
          end
        end)

      _ -> :ok
    end

    Logger.info("[FleetChannel] agent left fleet: #{agent_id}")
    :ok
  end

  # ── Private Helpers ─────────────────────────────────────────

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_sync_agent_metadata(nil, _payload), do: :ok

  defp maybe_sync_agent_metadata(%Auth.Agent{} = agent, join_payload) do
    updates =
      %{}
      |> maybe_update(:name, Map.get(join_payload, "name"), agent.name)
      |> maybe_update(:framework, Map.get(join_payload, "framework"), agent.framework)
      |> maybe_update(:capabilities, Map.get(join_payload, "capabilities"), agent.capabilities)

    # Sync model into metadata jsonb column
    new_model = Map.get(join_payload, "model")
    current_model = Map.get(agent.metadata || %{}, "model")

    updates =
      if new_model && new_model != "" && new_model != current_model do
        current_metadata = agent.metadata || %{}
        Map.put(updates, :metadata, Map.put(current_metadata, "model", new_model))
      else
        updates
      end

    if map_size(updates) > 0 do
      agent
      |> Auth.Agent.changeset(updates)
      |> Hub.Repo.update()
    else
      :ok
    end
  end

  defp maybe_update(map, _key, nil, _current), do: map
  defp maybe_update(map, _key, "", _current), do: map
  defp maybe_update(map, key, new_val, current) when new_val != current, do: Map.put(map, key, new_val)
  defp maybe_update(map, _key, _new_val, _current), do: map

  defp kanban_task_to_wire(%Hub.Schemas.KanbanTask{} = t) do
    %{
      "task_id" => t.task_id,
      "title" => t.title,
      "description" => t.description,
      "lane" => t.lane,
      "priority" => t.priority,
      "effort" => t.effort,
      "scope" => t.scope,
      "requires_capabilities" => t.requires_capabilities,
      "depends_on" => t.depends_on,
      "blocked_by" => t.blocked_by,
      "acceptance_criteria" => t.acceptance_criteria,
      "context_refs" => t.context_refs,
      "tags" => t.tags,
      "progress" => t.progress,
      "progress_pct" => t.progress_pct,
      "result" => t.result,
      "assigned_to" => t.assigned_to,
      "created_by" => t.created_by,
      "reviewed_by" => t.reviewed_by,
      "fleet_id" => t.fleet_id,
      "squad_id" => t.squad_id,
      "deadline" => t.deadline && DateTime.to_iso8601(t.deadline),
      "started_at" => t.started_at && DateTime.to_iso8601(t.started_at),
      "completed_at" => t.completed_at && DateTime.to_iso8601(t.completed_at),
      "position" => t.position,
      "inserted_at" => t.inserted_at && NaiveDateTime.to_iso8601(t.inserted_at)
    }
  end

  defp kanban_task_to_wire(other) when is_map(other), do: other

  defp maybe_put_squad(attrs, socket) do
    case socket.assigns[:squad_id] do
      nil -> attrs
      squad_id -> Map.put_new(attrs, "squad_id", squad_id)
    end
  end

  defp get_group_id_for_squad(squad_id) do
    case Hub.Repo.get(Hub.Groups.Group, squad_id) do
      nil -> nil
      group -> group.group_id
    end
  end

  defp fetch_agent(socket) do
    case Auth.find_agent(socket.assigns.agent_id) do
      {:ok, agent} -> agent
      _ -> nil
    end
  end

  defp build_meta(agent, join_payload) do
    %{
      agent_id: socket_agent_id(agent),
      name: agent_name(agent, join_payload),
      framework: Map.get(join_payload, "framework", agent_framework(agent)),
      model: Map.get(join_payload, "model", agent_model(agent)),
      capabilities: Map.get(join_payload, "capabilities", agent_capabilities(agent)),
      state: validated_state(Map.get(join_payload, "state", "online")),
      task: Map.get(join_payload, "task"),
      load: Map.get(join_payload, "load", 0.0),
      metadata: Map.get(join_payload, "metadata", %{}),
      connected_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      # Node-aware presence: track which BEAM node this agent is connected to
      node: Hub.NodeInfo.node_name_string(),
      region: Hub.NodeInfo.region(),
      node_region: Hub.NodeInfo.region()
    }
  end

  defp agent_model(nil), do: nil
  defp agent_model(agent), do: Map.get(agent.metadata || %{}, "model")

  defp socket_agent_id(nil), do: nil
  defp socket_agent_id(agent), do: agent.agent_id

  defp agent_name(nil, payload), do: Map.get(payload, "name", "unknown")
  defp agent_name(agent, payload), do: Map.get(payload, "name", agent.name || agent.agent_id)

  defp agent_framework(nil), do: "unknown"
  defp agent_framework(agent), do: agent.framework || "unknown"

  defp agent_capabilities(nil), do: []
  defp agent_capabilities(agent), do: agent.capabilities || []

  defp validated_state(state) when state in @valid_states, do: state
  defp validated_state(_), do: "online"

  defp group_topic(socket, group_id) do
    "fleet:#{socket.assigns.fleet_id}:group:#{group_id}"
  end

  defp group_json(group) do
    %{
      group_id: group.group_id,
      name: group.name,
      type: group.type,
      capabilities: group.capabilities,
      status: group.status,
      created_by: group.created_by,
      member_count: length(group.members || []),
      settings: group.settings,
      inserted_at: group.inserted_at
    }
  end

  defp get_current_meta(socket) do
    case FleetPresence.get_by_key(socket, socket.assigns.agent_id) do
      [] ->
        %{}

      %{metas: [meta | _]} ->
        meta

      %{metas: metas} when is_list(metas) ->
        List.first(metas, %{})

      _ ->
        %{}
    end
  end

  defp maybe_update(meta, key, payload) do
    str_key = Atom.to_string(key)

    case Map.get(payload, str_key) do
      nil -> meta
      value -> Map.put(meta, key, value)
    end
  end

  defp build_roster(socket) do
    topic = "fleet:#{socket.assigns.fleet_id}"

    FleetPresence.list(topic)
    |> Enum.flat_map(fn {agent_id, %{metas: metas}} ->
      Enum.map(metas, fn meta ->
        presence_payload(agent_id, meta)
      end)
    end)
  end

  defp presence_payload(agent_id, meta) do
    %{
      "agent_id" => agent_id,
      "name" => meta[:name] || meta["name"],
      "framework" => meta[:framework] || meta["framework"],
      "model" => meta[:model] || meta["model"],
      "capabilities" => meta[:capabilities] || meta["capabilities"] || [],
      "state" => meta[:state] || meta["state"],
      "task" => meta[:task] || meta["task"],
      "load" => meta[:load] || meta["load"] || 0.0,
      "connected_at" => meta[:connected_at] || meta["connected_at"],
      "node" => meta[:node] || meta["node"],
      "region" => meta[:region] || meta["region"]
    }
  end

  # ── Activity Helpers ────────────────────────────────────────

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

  defp get_agent_name(socket) do
    case FleetPresence.get_by_key(socket, socket.assigns.agent_id) do
      %{metas: [meta | _]} -> meta[:name] || socket.assigns.agent_id
      _ -> socket.assigns.agent_id
    end
  end

  defp broadcast_to_tagged(socket, tags, msg) do

    # Get all connected channel pids from Presence and filter by tag subscriptions
    # Since we can't iterate socket assigns of other processes directly,
    # we use PubSub with intercept for tagged delivery.
    # For now, broadcast to all and let clients filter, but also
    # use a tagged subtopic for efficient server-side filtering.
    Enum.each(tags, fn tag ->
      Phoenix.PubSub.broadcast(
        Hub.PubSub,
        "fleet:#{socket.assigns.fleet_id}:tag:#{tag}",
        {:tagged_activity, msg}
      )
    end)

    # Also broadcast on the main topic for clients that want everything
    # (they can filter client-side by tags)
    broadcast!(socket, "activity:broadcast", msg)
  end

  defp broadcast_to_agent(socket, target_agent_id, msg) do
    # Direct delivery via agent-specific PubSub topic
    Phoenix.PubSub.broadcast(
      Hub.PubSub,
      "fleet:#{socket.assigns.fleet_id}:agent:#{target_agent_id}",
      {:direct_activity, msg}
    )
  end

  # ── Memory Helpers ──────────────────────────────────────────

  defp maybe_opt(opts, _key, nil), do: opts
  defp maybe_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp pattern_matches?(pattern, key) do
    cond do
      pattern == "*" ->
        true

      String.ends_with?(pattern, "/*") ->
        prefix = String.trim_trailing(pattern, "/*")
        String.starts_with?(key, prefix <> "/")

      String.ends_with?(pattern, "*") ->
        prefix = String.trim_trailing(pattern, "*")
        String.starts_with?(key, prefix)

      true ->
        pattern == key
    end
  end

  # ── Squad Helpers ────────────────────────────────────────

  # Require the agent to be in a squad. Returns {:ok, squad_id} or {:error, map}.
  defp require_squad(socket) do
    case socket.assigns[:squad_id] do
      nil -> {:error, %{reason: "no_squad", message: "You are not assigned to a squad."}}
      squad_id -> {:ok, squad_id}
    end
  end

  # Require the agent to be a squad leader (admin or owner in GroupMember).
  defp require_squad_leader(socket) do
    case require_squad(socket) do
      {:error, _} = err ->
        err

      {:ok, squad_id} ->
        agent_id = socket.assigns.agent_id

        # Look up group_id from squad_id (which is the binary FK to groups table)
        # squad_id on Agent is the groups.id (binary_id), we need the group_id string
        case Hub.Repo.get(Hub.Groups.Group, squad_id) do
          nil ->
            {:error, %{reason: "squad_not_found", message: "Squad not found."}}

          group ->
            case Hub.Groups.member_role(group.group_id, agent_id) do
              {:ok, role} when role in ["admin", "owner"] ->
                {:ok, squad_id}

              {:ok, _} ->
                {:error, %{reason: "not_leader", message: "Only squad leaders (admin/owner) can perform this action."}}

              {:error, :not_member} ->
                {:error, %{reason: "not_member", message: "You are not a member of this squad's group."}}

              {:error, _} ->
                {:error, %{reason: "squad_error", message: "Could not verify squad role."}}
            end
        end
    end
  end

  # Get all agent_ids in a squad (by squad's DB id which is groups.id)
  defp get_squad_agent_ids(squad_id) do
    import Ecto.Query

    Hub.Repo.all(
      from a in Hub.Auth.Agent,
        where: a.squad_id == ^squad_id,
        select: a.agent_id
    )
  end

  # ── Idempotency Helpers ──────────────────────────────────

  # Extract the idempotency key from a payload, scoped to this fleet+agent.
  defp extract_idempotency_key(payload, socket) do
    case get_in(payload, ["payload", "_idempotency_key"]) || Map.get(payload, "_idempotency_key") do
      nil -> nil
      "" -> nil
      raw_key ->
        # Scope the key to fleet+agent to prevent cross-tenant collisions
        "#{socket.assigns.fleet_id}:#{socket.assigns.agent_id}:#{raw_key}"
    end
  end

  # Check idempotency cache. Returns {:hit, reply, socket} or :miss.
  defp check_idempotency(nil, _socket), do: :miss
  defp check_idempotency(key, socket) do
    case Hub.Quota.idempotency_check(key) do
      {:hit, cached_reply} -> {:hit, cached_reply, socket}
      :miss -> :miss
    end
  end

  # Store a successful reply in the idempotency cache.
  defp store_idempotency(nil, _reply), do: :ok
  defp store_idempotency(key, reply) do
    Hub.Quota.idempotency_store(key, reply)
  end

  # ── Quota Helpers ──────────────────────────────────────────

  defp quota_ok?(tenant_id, resource) do
    case Hub.Quota.check(tenant_id, resource) do
      {:ok, :unlimited} -> true
      {:ok, %{remaining: remaining}} when remaining > 0 -> true
      _ -> false
    end
  end
end
