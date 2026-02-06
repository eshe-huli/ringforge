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

  @valid_states ~w(online busy away offline)
  @valid_activity_kinds ~w(task_started task_progress task_completed task_failed discovery question alert custom)

  # ── Join ────────────────────────────────────────────────────

  @impl true
  def join("fleet:" <> fleet_id, payload, socket) do
    # Verify the socket's fleet_id matches the requested topic
    if socket.assigns.fleet_id != fleet_id do
      {:error, %{reason: "fleet_id mismatch"}}
    else
      send(self(), {:after_join, payload})
      {:ok, socket}
    end
  end

  @impl true
  def handle_info({:after_join, payload}, socket) do
    agent = fetch_agent(socket)
    join_payload = Map.get(payload, "payload", %{})

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

  # ── presence:update — client updates their state ───────────

  @impl true
  def handle_in("presence:update", %{"payload" => update_payload}, socket) do
    state = Map.get(update_payload, "state")

    if state && state not in @valid_states do
      {:reply, {:error, %{reason: "invalid state, must be one of: #{Enum.join(@valid_states, ", ")}"}}, socket}
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
        {:reply, {:error, %{reason: "invalid kind, must be one of: #{Enum.join(@valid_activity_kinds, ", ")}"}}, socket}

      true ->
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

  # ── Terminate — cleanup on disconnect ──────────────────────

  @impl true
  def terminate(_reason, socket) do
    agent_id = socket.assigns.agent_id

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
end
