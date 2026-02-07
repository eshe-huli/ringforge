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

    # Ensure webhook subscriber is listening to this fleet's topic
    Hub.WebhookSubscriber.subscribe_fleet(socket.assigns.fleet_id)

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
        |> maybe_update(:metadata, update_payload)

      # Update presence tracking
      FleetPresence.update(socket, socket.assigns.agent_id, updated_meta)

      # Broadcast state change
      broadcast!(socket, "presence:state_changed", %{
        "type" => "presence",
        "event" => "state_changed",
        "payload" => %{
          "agent_id" => socket.assigns.agent_id,
          "name" => updated_meta[:name],
          "state" => updated_meta[:state],
          "task" => updated_meta[:task],
          "load" => updated_meta[:load]
        }
      })

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
      capabilities: Map.get(join_payload, "capabilities", agent_capabilities(agent)),
      state: validated_state(Map.get(join_payload, "state", "online")),
      task: Map.get(join_payload, "task"),
      load: Map.get(join_payload, "load", 0.0),
      metadata: Map.get(join_payload, "metadata", %{}),
      connected_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

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
      "capabilities" => meta[:capabilities] || meta["capabilities"] || [],
      "state" => meta[:state] || meta["state"],
      "task" => meta[:task] || meta["task"],
      "load" => meta[:load] || meta["load"] || 0.0,
      "connected_at" => meta[:connected_at] || meta["connected_at"]
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
