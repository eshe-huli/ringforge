defmodule Hub.WebhookSubscriber do
  @moduledoc """
  Subscribes to Phoenix PubSub topics and dispatches matching events
  to the WebhookDispatcher.

  This module bridges the internal PubSub event system with the outbound
  webhook delivery pipeline. It listens to fleet-level broadcasts and
  translates them into webhook event types.

  Started as part of the application supervision tree.
  """

  use GenServer

  require Logger

  alias Hub.WebhookDispatcher

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Subscribe to the Hub.Events topic used by the dashboard
    Hub.Events.subscribe()

    # We also listen for fleet-wide broadcasts
    # New fleet topics are subscribed dynamically when we see them
    {:ok, %{fleet_topics: MapSet.new()}}
  end

  @doc """
  Subscribe to a specific fleet's PubSub topic for webhook dispatching.
  Called when agents connect to ensure we're listening.
  """
  def subscribe_fleet(fleet_id) do
    GenServer.cast(__MODULE__, {:subscribe_fleet, fleet_id})
  end

  @impl true
  def handle_cast({:subscribe_fleet, fleet_id}, state) do
    topic = "fleet:#{fleet_id}"

    if MapSet.member?(state.fleet_topics, topic) do
      {:noreply, state}
    else
      Phoenix.PubSub.subscribe(Hub.PubSub, topic)
      {:noreply, %{state | fleet_topics: MapSet.put(state.fleet_topics, topic)}}
    end
  end

  # ── PubSub Event Handlers ─────────────────────────────────

  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{event: "presence:joined", payload: payload}, state) do
    p = payload["payload"] || payload
    fleet_id = extract_fleet_id(p)

    WebhookDispatcher.dispatch("agent.connected", %{
      "agent_id" => p["agent_id"],
      "name" => p["name"],
      "state" => p["state"]
    }, fleet_id)

    {:noreply, state}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence:left", payload: payload}, state) do
    p = payload["payload"] || payload
    fleet_id = extract_fleet_id(p)

    WebhookDispatcher.dispatch("agent.disconnected", %{
      "agent_id" => p["agent_id"]
    }, fleet_id)

    {:noreply, state}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "activity:broadcast", payload: payload}, state) do
    p = payload["payload"] || payload
    fleet_id = extract_fleet_id(p)

    WebhookDispatcher.dispatch("activity.broadcast", %{
      "kind" => p["kind"],
      "description" => p["description"],
      "tags" => p["tags"] || [],
      "from" => p["from"],
      "data" => p["data"] || %{}
    }, fleet_id)

    {:noreply, state}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "file:shared", payload: payload}, state) do
    p = payload["payload"] || payload
    fleet_id = extract_fleet_id(p)

    WebhookDispatcher.dispatch("file.shared", p, fleet_id)
    {:noreply, state}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "file:deleted", payload: payload}, state) do
    p = payload["payload"] || payload
    fleet_id = extract_fleet_id(p)

    WebhookDispatcher.dispatch("file.deleted", p, fleet_id)
    {:noreply, state}
  end

  # Hub.Events for internal events
  def handle_info({:hub_event, %{type: "task", action: "submitted"} = event}, state) do
    WebhookDispatcher.dispatch("task.submitted", event.data, event[:fleet_id])
    {:noreply, state}
  end

  def handle_info({:hub_event, %{type: "task", action: "completed"} = event}, state) do
    WebhookDispatcher.dispatch("task.completed", event.data, event[:fleet_id])
    {:noreply, state}
  end

  def handle_info({:hub_event, %{type: "task", action: "failed"} = event}, state) do
    WebhookDispatcher.dispatch("task.failed", event.data, event[:fleet_id])
    {:noreply, state}
  end

  def handle_info({:hub_event, %{type: "memory", action: "changed"} = event}, state) do
    WebhookDispatcher.dispatch("memory.changed", event.data, event[:fleet_id])
    {:noreply, state}
  end

  def handle_info({:hub_event, %{type: "direct_message"} = event}, state) do
    WebhookDispatcher.dispatch("message.received", event.data, event[:fleet_id])
    {:noreply, state}
  end

  # Catch-all for unhandled messages
  def handle_info(_msg, state), do: {:noreply, state}

  # ── Helpers ────────────────────────────────────────────────

  defp extract_fleet_id(%{"fleet_id" => fid}) when is_binary(fid), do: fid
  defp extract_fleet_id(_), do: nil
end
