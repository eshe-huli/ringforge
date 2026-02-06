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
end
