defmodule Hub.Live.DashboardLive do
  @moduledoc """
  Real-time operator dashboard for Ringforge fleets.

  Displays connected agents, activity feed, messaging, and quota usage
  in a single-page LiveView. All updates are PubSub-driven — no polling.

  ## Authentication

  Accepts `?key=rf_admin_...` as a query parameter on first visit.
  The admin API key is validated and tenant_id stored in the LiveView assigns.
  """
  use Phoenix.LiveView

  alias Hub.FleetPresence

  @activity_limit 50

  # ── Mount ──────────────────────────────────────────────────

  @impl true
  def mount(params, session, socket) do
    case authenticate(params, session) do
      {:ok, tenant_id, fleet_id, fleet_name} ->
        socket = assign(socket,
          tenant_id: tenant_id,
          fleet_id: fleet_id,
          fleet_name: fleet_name,
          agents: %{},
          activities: [],
          usage: %{},
          selected_agent: nil,
          msg_to: "",
          msg_body: "",
          msg_status: nil,
          filter: "all",
          authenticated: true
        )

        if connected?(socket) do
          Hub.Events.subscribe()
          Phoenix.PubSub.subscribe(Hub.PubSub, "fleet:#{fleet_id}")
          Process.send_after(self(), :refresh_quota, 1_000)
        end

        agents = load_agents(fleet_id)
        activities = load_recent_activities(fleet_id)
        usage = load_usage(tenant_id)

        socket = assign(socket,
          agents: agents,
          activities: activities,
          usage: usage
        )

        {:ok, socket}

      {:error, :unauthenticated} ->
        socket = assign(socket,
          authenticated: false,
          auth_error: nil,
          key_input: ""
        )

        {:ok, socket}
    end
  end

  # ── Events ─────────────────────────────────────────────────

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("authenticate", %{"key" => key}, socket) do
    case validate_admin_key(key) do
      {:ok, tenant_id, fleet_id, fleet_name} ->
        socket = assign(socket,
          tenant_id: tenant_id,
          fleet_id: fleet_id,
          fleet_name: fleet_name,
          agents: load_agents(fleet_id),
          activities: load_recent_activities(fleet_id),
          usage: load_usage(tenant_id),
          selected_agent: nil,
          msg_to: "",
          msg_body: "",
          msg_status: nil,
          filter: "all",
          authenticated: true,
          auth_error: nil
        )

        if connected?(socket) do
          Hub.Events.subscribe()
          Phoenix.PubSub.subscribe(Hub.PubSub, "fleet:#{fleet_id}")
          Process.send_after(self(), :refresh_quota, 1_000)
        end

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, assign(socket, auth_error: "Invalid admin API key")}
    end
  end

  def handle_event("select_agent", %{"agent-id" => agent_id}, socket) do
    {:noreply, assign(socket, selected_agent: agent_id, msg_to: agent_id)}
  end

  def handle_event("update_msg_to", %{"value" => value}, socket) do
    {:noreply, assign(socket, msg_to: value)}
  end

  def handle_event("update_msg_body", %{"value" => value}, socket) do
    {:noreply, assign(socket, msg_body: value)}
  end

  def handle_event("send_message", %{"to" => to, "body" => body}, socket) do
    fleet_id = socket.assigns.fleet_id

    case Hub.DirectMessage.send_message(fleet_id, "dashboard", to, %{"text" => body}) do
      {:ok, result} ->
        {:noreply, assign(socket, msg_body: "", msg_status: {:ok, result.status})}

      {:error, reason} ->
        {:noreply, assign(socket, msg_status: {:error, reason})}
    end
  end

  def handle_event("set_filter", %{"filter" => filter}, socket) do
    {:noreply, assign(socket, filter: filter)}
  end

  def handle_event("clear_msg_status", _, socket) do
    {:noreply, assign(socket, msg_status: nil)}
  end

  # ── PubSub Handlers ───────────────────────────────────────

  @impl true
  def handle_info({:hub_event, event}, socket) do
    socket = handle_hub_event(event, socket)
    {:noreply, socket}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff", payload: diff}, socket) do
    agents = socket.assigns.agents

    agents =
      Enum.reduce(Map.get(diff, :joins, %{}), agents, fn {agent_id, %{metas: [meta | _]}}, acc ->
        Map.put(acc, agent_id, normalize_meta(meta))
      end)

    agents =
      Enum.reduce(Map.get(diff, :leaves, %{}), agents, fn {agent_id, _}, acc ->
        Map.delete(acc, agent_id)
      end)

    {:noreply, assign(socket, agents: agents)}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence:joined", payload: payload}, socket) do
    p = payload["payload"] || payload
    agent_id = p["agent_id"]

    if agent_id do
      agent_meta = %{
        name: p["name"] || agent_id,
        state: p["state"] || "online",
        capabilities: p["capabilities"] || [],
        task: p["task"],
        framework: p["framework"],
        connected_at: p["connected_at"]
      }

      agents = Map.put(socket.assigns.agents, agent_id, agent_meta)

      activity = %{
        kind: "join",
        agent_id: agent_id,
        agent_name: agent_meta.name,
        description: "connected to fleet",
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      activities = prepend_activity(socket.assigns.activities, activity)
      {:noreply, assign(socket, agents: agents, activities: activities)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence:left", payload: payload}, socket) do
    p = payload["payload"] || payload
    agent_id = p["agent_id"]

    if agent_id do
      agent_name =
        case Map.get(socket.assigns.agents, agent_id) do
          %{name: name} -> name
          _ -> agent_id
        end

      agents = Map.delete(socket.assigns.agents, agent_id)

      activity = %{
        kind: "leave",
        agent_id: agent_id,
        agent_name: agent_name,
        description: "disconnected from fleet",
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      activities = prepend_activity(socket.assigns.activities, activity)
      {:noreply, assign(socket, agents: agents, activities: activities)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence:state_changed", payload: payload}, socket) do
    p = payload["payload"] || payload
    agent_id = p["agent_id"]

    if agent_id do
      agents =
        Map.update(socket.assigns.agents, agent_id, %{}, fn existing ->
          existing
          |> Map.put(:state, p["state"] || existing[:state])
          |> Map.put(:task, p["task"] || existing[:task])
          |> Map.put(:name, p["name"] || existing[:name])
        end)

      {:noreply, assign(socket, agents: agents)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "activity:broadcast", payload: payload}, socket) do
    p = payload["payload"] || payload

    activity = %{
      kind: p["kind"] || "custom",
      agent_id: get_in(p, ["from", "agent_id"]) || "unknown",
      agent_name: get_in(p, ["from", "name"]) || "unknown",
      description: p["description"] || "",
      tags: p["tags"] || [],
      timestamp: p["timestamp"] || DateTime.utc_now() |> DateTime.to_iso8601()
    }

    activities = prepend_activity(socket.assigns.activities, activity)
    {:noreply, assign(socket, activities: activities)}
  end

  def handle_info({:quota_warning, _msg}, socket) do
    usage = load_usage(socket.assigns.tenant_id)
    {:noreply, assign(socket, usage: usage)}
  end

  def handle_info(:refresh_quota, socket) do
    if socket.assigns[:authenticated] do
      usage = load_usage(socket.assigns.tenant_id)
      Process.send_after(self(), :refresh_quota, 5_000)
      {:noreply, assign(socket, usage: usage)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(%Phoenix.Socket.Broadcast{}, socket), do: {:noreply, socket}
  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── Render ─────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    if assigns[:authenticated] do
      render_dashboard(assigns)
    else
      render_login(assigns)
    end
  end

  defp render_login(assigns) do
    ~H"""
    <div class="min-h-screen flex items-center justify-center bg-gray-950">
      <div class="bg-gray-900 rounded-lg border border-gray-800 p-8 w-full max-w-md shadow-xl">
        <div class="text-center mb-6">
          <h1 class="text-2xl font-bold text-amber-400">🔨 RingForge</h1>
          <p class="text-gray-400 mt-2 text-sm">Enter your admin API key to continue</p>
        </div>

        <form phx-submit="authenticate" class="space-y-4">
          <div>
            <input
              type="password"
              name="key"
              value={@key_input}
              placeholder="rf_admin_..."
              autocomplete="off"
              class="w-full px-4 py-3 bg-gray-800 border border-gray-700 rounded-lg text-gray-100 placeholder-gray-500 focus:outline-none focus:border-amber-500 focus:ring-1 focus:ring-amber-500 font-mono text-sm"
            />
          </div>

          <%= if @auth_error do %>
            <div class="text-red-400 text-sm text-center"><%= @auth_error %></div>
          <% end %>

          <button
            type="submit"
            class="w-full py-3 bg-amber-600 hover:bg-amber-500 text-gray-950 font-bold rounded-lg transition-colors"
          >
            Access Dashboard
          </button>
        </form>
      </div>
    </div>
    """
  end

  defp render_dashboard(assigns) do
    agents_sorted = assigns.agents
      |> Enum.sort_by(fn {_id, m} -> state_sort_order(m[:state]) end)

    filtered = filtered_activities(assigns.activities, assigns.filter)

    assigns = assign(assigns, agents_sorted: agents_sorted, filtered_activities: filtered)

    ~H"""
    <div class="h-screen flex flex-col overflow-hidden">
      <%!-- Header --%>
      <header class="flex items-center justify-between px-6 py-3 bg-gray-900 border-b border-gray-800 shrink-0">
        <div class="flex items-center gap-3">
          <span class="text-xl">🔨</span>
          <h1 class="text-lg font-bold text-amber-400">RingForge Dashboard</h1>
        </div>
        <div class="flex items-center gap-4">
          <span class="text-sm text-gray-400">
            Fleet: <span class="text-gray-200"><%= @fleet_name %></span>
          </span>
          <span class="text-xs px-2 py-1 bg-green-900/50 text-green-400 rounded border border-green-800">
            LIVE
          </span>
        </div>
      </header>

      <%!-- Main grid --%>
      <div class="flex-1 grid grid-cols-[280px_1fr] grid-rows-[1fr_220px] min-h-0">

        <%!-- Left sidebar: Agents --%>
        <div class="border-r border-gray-800 overflow-y-auto bg-gray-900/50">
          <div class="p-4">
            <h2 class="text-xs font-bold text-gray-500 uppercase tracking-wider mb-3">
              Agents
              <span class="ml-2 text-amber-400"><%= map_size(@agents) %></span>
            </h2>

            <%= if map_size(@agents) == 0 do %>
              <div class="text-gray-600 text-sm italic py-4">No agents connected</div>
            <% end %>

            <%= for {agent_id, meta} <- @agents_sorted do %>
              <div
                phx-click="select_agent"
                phx-value-agent-id={agent_id}
                class={"p-3 rounded-lg mb-2 cursor-pointer transition-colors border " <> if(@selected_agent == agent_id, do: "border-amber-500/50 bg-amber-500/10", else: "border-transparent hover:bg-gray-800/50")}
              >
                <div class="flex items-center gap-2">
                  <span class={"inline-block w-2.5 h-2.5 rounded-full " <> state_color(meta[:state]) <> if(meta[:state] in ["online", "busy"], do: " pulse-dot", else: "")}></span>
                  <span class="font-medium text-sm text-gray-100 truncate"><%= meta[:name] || agent_id %></span>
                </div>
                <div class="ml-5 mt-1">
                  <span class="text-xs text-gray-500"><%= meta[:state] || "unknown" %></span>
                  <%= if meta[:task] do %>
                    <div class="text-xs text-gray-400 mt-0.5 truncate" title={meta[:task]}>
                      📋 <%= meta[:task] %>
                    </div>
                  <% end %>
                  <%= if meta[:capabilities] && meta[:capabilities] != [] do %>
                    <div class="flex flex-wrap gap-1 mt-1">
                      <%= for cap <- Enum.take(List.wrap(meta[:capabilities]), 4) do %>
                        <span class="text-[10px] px-1.5 py-0.5 bg-gray-800 text-gray-400 rounded"><%= cap %></span>
                      <% end %>
                    </div>
                  <% end %>
                </div>
              </div>
            <% end %>
          </div>
        </div>

        <%!-- Main area: Activity Feed --%>
        <div class="overflow-hidden flex flex-col bg-gray-950">
          <div class="px-4 py-3 border-b border-gray-800 flex items-center justify-between shrink-0">
            <h2 class="text-xs font-bold text-gray-500 uppercase tracking-wider">Activity Feed</h2>
            <div class="flex gap-1">
              <%= for {label, value} <- [{"All", "all"}, {"Tasks", "tasks"}, {"Discoveries", "discoveries"}, {"Alerts", "alerts"}] do %>
                <button
                  phx-click="set_filter"
                  phx-value-filter={value}
                  class={"text-xs px-2.5 py-1 rounded transition-colors " <> if(@filter == value, do: "bg-amber-600/20 text-amber-400 border border-amber-600/40", else: "text-gray-500 hover:text-gray-300 border border-transparent")}
                >
                  <%= label %>
                </button>
              <% end %>
            </div>
          </div>

          <div class="flex-1 overflow-y-auto p-4 space-y-1" id="activity-feed">
            <%= if @filtered_activities == [] do %>
              <div class="text-gray-600 text-sm italic py-8 text-center">No activity yet</div>
            <% end %>

            <%= for activity <- @filtered_activities do %>
              <div class="fade-in flex gap-3 py-2 px-3 rounded hover:bg-gray-900/50 group">
                <span class="text-xs text-gray-600 whitespace-nowrap mt-0.5 font-mono">
                  <%= format_time(activity.timestamp) %>
                </span>
                <span class="text-sm"><%= kind_icon(activity.kind) %></span>
                <div class="min-w-0 flex-1">
                  <span class={"text-sm font-medium " <> kind_color(activity.kind)}><%= activity.agent_name %>:</span>
                  <span class="text-sm text-gray-300 ml-1"><%= activity.kind %></span>
                  <div class="text-xs text-gray-500 truncate mt-0.5"><%= activity.description %></div>
                </div>
              </div>
            <% end %>
          </div>
        </div>

        <%!-- Bottom left: Send Message --%>
        <div class="border-r border-t border-gray-800 bg-gray-900/50 p-4 overflow-y-auto">
          <h2 class="text-xs font-bold text-gray-500 uppercase tracking-wider mb-3">Send Message</h2>
          <form phx-submit="send_message" class="space-y-2">
            <div>
              <label class="text-xs text-gray-500">To</label>
              <input
                type="text"
                name="to"
                value={@msg_to}
                phx-keyup="update_msg_to"
                placeholder="agent_id"
                class="w-full px-3 py-2 bg-gray-800 border border-gray-700 rounded text-sm text-gray-100 placeholder-gray-600 focus:outline-none focus:border-amber-500 font-mono"
              />
            </div>
            <div>
              <label class="text-xs text-gray-500">Message</label>
              <textarea
                name="body"
                phx-keyup="update_msg_body"
                placeholder="Type a message..."
                rows="2"
                class="w-full px-3 py-2 bg-gray-800 border border-gray-700 rounded text-sm text-gray-100 placeholder-gray-600 focus:outline-none focus:border-amber-500 font-mono resize-none"
              ><%= @msg_body %></textarea>
            </div>
            <button
              type="submit"
              class="w-full py-2 bg-amber-600 hover:bg-amber-500 text-gray-950 font-bold rounded text-sm transition-colors disabled:opacity-50"
            >
              Send →
            </button>
            <%= if @msg_status do %>
              <div class={"text-xs text-center mt-1 " <> msg_status_color(@msg_status)} phx-click="clear_msg_status">
                <%= msg_status_text(@msg_status) %>
              </div>
            <% end %>
          </form>
        </div>

        <%!-- Bottom right: Quota Usage --%>
        <div class="border-t border-gray-800 bg-gray-950 p-4 overflow-y-auto">
          <h2 class="text-xs font-bold text-gray-500 uppercase tracking-wider mb-3">Quota Usage</h2>
          <div class="grid grid-cols-2 gap-4">
            <%= for {resource, label, icon} <- quota_resources() do %>
              <% info = Map.get(@usage, resource, %{used: 0, limit: 0}) %>
              <% pct = quota_percentage(info) %>
              <div class="space-y-1.5">
                <div class="flex items-center justify-between text-xs">
                  <span class="text-gray-400"><%= icon %> <%= label %></span>
                  <span class="text-gray-500 font-mono">
                    <%= format_quota_number(info[:used] || Map.get(info, :used, 0)) %>/<%= format_quota_limit(info[:limit] || Map.get(info, :limit, 0)) %>
                  </span>
                </div>
                <div class="h-2 bg-gray-800 rounded-full overflow-hidden">
                  <div
                    class={"h-full rounded-full transition-all duration-500 " <> quota_bar_color(pct)}
                    style={"width: #{pct}%"}
                  ></div>
                </div>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── Authentication ─────────────────────────────────────────

  defp authenticate(params, session) do
    cond do
      key = params["key"] ->
        validate_admin_key(key)

      tenant_id = session["tenant_id"] ->
        fleet = load_default_fleet(tenant_id)
        if fleet, do: {:ok, tenant_id, fleet.id, fleet.name}, else: {:error, :unauthenticated}

      true ->
        {:error, :unauthenticated}
    end
  end

  defp validate_admin_key(raw_key) do
    case Hub.Auth.validate_api_key(raw_key) do
      {:ok, %{type: "admin", tenant_id: tenant_id}} ->
        fleet = load_default_fleet(tenant_id)
        if fleet do
          {:ok, tenant_id, fleet.id, fleet.name}
        else
          {:error, :no_fleet}
        end

      {:ok, _non_admin} ->
        {:error, :not_admin}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Data Loading ───────────────────────────────────────────

  defp load_default_fleet(tenant_id) do
    import Ecto.Query
    Hub.Repo.one(
      from(f in Hub.Auth.Fleet,
        where: f.tenant_id == ^tenant_id,
        order_by: [asc: f.inserted_at],
        limit: 1
      )
    )
  end

  defp load_agents(fleet_id) do
    topic = "fleet:#{fleet_id}"

    case FleetPresence.list(topic) do
      presences when is_map(presences) ->
        Map.new(presences, fn {agent_id, %{metas: [meta | _]}} ->
          {agent_id, normalize_meta(meta)}
        end)

      _ ->
        %{}
    end
  end

  defp normalize_meta(meta) do
    %{
      name: meta[:name] || meta["name"],
      state: meta[:state] || meta["state"] || "online",
      capabilities: meta[:capabilities] || meta["capabilities"] || [],
      task: meta[:task] || meta["task"],
      framework: meta[:framework] || meta["framework"],
      connected_at: meta[:connected_at] || meta["connected_at"]
    }
  end

  defp load_recent_activities(fleet_id) do
    bus_topic = "ringforge.#{fleet_id}.activity"

    case Hub.EventBus.replay(bus_topic, limit: @activity_limit) do
      {:ok, events} ->
        Enum.map(events, fn event ->
          %{
            kind: event["kind"] || "custom",
            agent_id: get_in(event, ["from", "agent_id"]) || "unknown",
            agent_name: get_in(event, ["from", "name"]) || "unknown",
            description: event["description"] || "",
            tags: event["tags"] || [],
            timestamp: event["timestamp"] || ""
          }
        end)
        |> Enum.reverse()

      {:error, _} ->
        []
    end
  end

  defp load_usage(tenant_id) do
    Hub.Quota.get_usage(tenant_id)
  end

  # ── Hub Event Handler ──────────────────────────────────────

  defp handle_hub_event(%{type: :activity_published, payload: payload}, socket) do
    fleet_id = socket.assigns.fleet_id

    if payload[:fleet_id] == fleet_id do
      activity = %{
        kind: payload[:kind] || "custom",
        agent_id: payload[:agent_id] || "unknown",
        agent_name: payload[:agent_name] || "unknown",
        description: payload[:description] || "",
        tags: payload[:tags] || [],
        timestamp: payload[:timestamp] || DateTime.utc_now() |> DateTime.to_iso8601()
      }

      assign(socket, activities: prepend_activity(socket.assigns.activities, activity))
    else
      socket
    end
  end

  defp handle_hub_event(_event, socket), do: socket

  # ── Helpers ────────────────────────────────────────────────

  defp prepend_activity(activities, activity) do
    [activity | activities] |> Enum.take(@activity_limit)
  end

  defp filtered_activities(activities, "all"), do: activities

  defp filtered_activities(activities, "tasks") do
    Enum.filter(activities, fn a ->
      a.kind in ~w(task_started task_progress task_completed task_failed)
    end)
  end

  defp filtered_activities(activities, "discoveries") do
    Enum.filter(activities, fn a -> a.kind == "discovery" end)
  end

  defp filtered_activities(activities, "alerts") do
    Enum.filter(activities, fn a -> a.kind in ~w(alert question) end)
  end

  defp filtered_activities(activities, _), do: activities

  defp format_time(nil), do: "--:--"
  defp format_time(""), do: "--:--"

  defp format_time(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%H:%M")
      _ -> "--:--"
    end
  end

  defp format_time(_), do: "--:--"

  defp kind_icon("task_started"), do: "🚀"
  defp kind_icon("task_progress"), do: "⏳"
  defp kind_icon("task_completed"), do: "✅"
  defp kind_icon("task_failed"), do: "❌"
  defp kind_icon("discovery"), do: "💡"
  defp kind_icon("question"), do: "❓"
  defp kind_icon("alert"), do: "🚨"
  defp kind_icon("join"), do: "🟢"
  defp kind_icon("leave"), do: "🔴"
  defp kind_icon(_), do: "📌"

  defp kind_color("task_completed"), do: "text-green-400"
  defp kind_color("task_started"), do: "text-blue-400"
  defp kind_color("task_progress"), do: "text-cyan-400"
  defp kind_color("task_failed"), do: "text-red-400"
  defp kind_color("discovery"), do: "text-purple-400"
  defp kind_color("question"), do: "text-yellow-400"
  defp kind_color("alert"), do: "text-red-400"
  defp kind_color("join"), do: "text-green-400"
  defp kind_color("leave"), do: "text-gray-500"
  defp kind_color(_), do: "text-gray-400"

  defp state_color("online"), do: "bg-green-400"
  defp state_color("busy"), do: "bg-yellow-400"
  defp state_color("away"), do: "bg-gray-400"
  defp state_color("offline"), do: "bg-red-500"
  defp state_color(_), do: "bg-gray-600"

  defp state_sort_order("online"), do: 0
  defp state_sort_order("busy"), do: 1
  defp state_sort_order("away"), do: 2
  defp state_sort_order("offline"), do: 3
  defp state_sort_order(_), do: 4

  defp quota_resources do
    [
      {:connected_agents, "Agents", "👤"},
      {:messages_today, "Messages", "💬"},
      {:memory_entries, "Memory", "🧠"},
      {:fleets, "Fleets", "🚢"}
    ]
  end

  defp quota_percentage(%{used: _, limit: :unlimited}), do: 0
  defp quota_percentage(%{used: _used, limit: 0}), do: 0
  defp quota_percentage(%{used: used, limit: limit}) when is_integer(limit) and limit > 0 do
    min(round(used / limit * 100), 100)
  end
  defp quota_percentage(_), do: 0

  defp quota_bar_color(pct) when pct >= 95, do: "bg-red-500"
  defp quota_bar_color(pct) when pct >= 80, do: "bg-yellow-500"
  defp quota_bar_color(_), do: "bg-green-500"

  defp format_quota_number(n) when is_integer(n) and n >= 1000 do
    "#{Float.round(n / 1000, 1)}K"
  end
  defp format_quota_number(n), do: "#{n}"

  defp format_quota_limit(:unlimited), do: "∞"
  defp format_quota_limit(n) when is_integer(n) and n >= 1000 do
    "#{Float.round(n / 1000, 1)}K"
  end
  defp format_quota_limit(n), do: "#{n}"

  defp msg_status_color({:ok, _}), do: "text-green-400"
  defp msg_status_color({:error, _}), do: "text-red-400"

  defp msg_status_text({:ok, status}), do: "✓ Message #{status}"
  defp msg_status_text({:error, reason}), do: "✗ #{reason}"
end
