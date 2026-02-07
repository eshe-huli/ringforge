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

  # ── Join ────────────────────────────────────────────────────

  @impl true
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

  def handle_in("activity:broadcast", %{"payload" => payload}, socket) do
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

        {:reply, {:ok, %{event_id: event_id}}, socket}
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

  def handle_in("memory:set", %{"payload" => payload}, socket) do
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
            {:reply, {:ok, %{id: entry["id"], key: entry["key"], version: 1}}, socket}
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

  def handle_in("direct:send", %{"payload" => payload}, socket) do
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
        case DirectMessage.send_message(
               socket.assigns.fleet_id,
               socket.assigns.agent_id,
               to,
               message,
               correlation_id
             ) do
          {:ok, result} ->
            {:reply, {:ok, %{
              "type" => "direct",
              "event" => "delivered",
              "payload" => %{
                "message_id" => result.message_id,
                "to" => to,
                "status" => result.status
              }
            }}, socket}

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

  # ── Groups ──────────────────────────────────────────────────

  def handle_in("group:create", %{"payload" => payload}, socket) do
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

        {:reply, {:ok, group_json(group)}, socket}

      {:error, changeset} ->
        {:reply, {:error, %{message: "Failed to create group", details: inspect(changeset.errors)}}, socket}
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

  def handle_info({:group_invite, invite}, socket) do
    push(socket, "group:invite", %{
      "type" => "group", "event" => "invite",
      "payload" => invite
    })
    {:noreply, socket}
  end

  # ── Terminate — cleanup on disconnect ──────────────────────

  @impl true
  def terminate(_reason, socket) do
    agent_id = socket.assigns.agent_id

    # Decrement connected_agents quota
    Hub.Quota.decrement(socket.assigns.tenant_id, :connected_agents)

    # Broadcast left event
    broadcast!(socket, "presence:left", %{
      "type" => "presence",
      "event" => "left",
      "payload" => %{
        "agent_id" => agent_id
      }
    })

    # Update last_seen_at in DB
    case Auth.find_agent(agent_id) do
      {:ok, agent} -> Auth.touch_agent(agent)
      _ -> :ok
    end

    Logger.info("[FleetChannel] agent left fleet: #{agent_id}")
    :ok
  end

  # ── Private Helpers ─────────────────────────────────────────

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

  # ── Quota Helpers ──────────────────────────────────────────

  defp quota_ok?(tenant_id, resource) do
    case Hub.Quota.check(tenant_id, resource) do
      {:ok, :unlimited} -> true
      {:ok, %{remaining: remaining}} when remaining > 0 -> true
      _ -> false
    end
  end
end
