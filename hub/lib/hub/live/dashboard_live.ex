defmodule Hub.Live.DashboardLive do
  @moduledoc """
  Production-grade operator dashboard for Ringforge fleets.

  Multi-view LiveView with sidebar navigation supporting:
  - Dashboard (overview with stats, agent grid, activity feed, quotas)
  - Agents (sortable table with slide-in detail panel)
  - Activity (full filterable stream with time grouping)
  - Messaging (conversation-style DM view)
  - Quotas & Metrics (large visual bars, plan info, warnings)
  - Settings (fleet configuration)

  All updates are PubSub-driven — no polling (except quota refresh).

  ## Authentication
  Accepts `?key=rf_admin_...` as a query parameter on first visit.
  """
  use Phoenix.LiveView

  alias Hub.FleetPresence
  alias Hub.Live.Components

  @activity_limit 100

  # ── Mount ──────────────────────────────────────────────────

  @impl true
  def mount(params, session, socket) do
    case authenticate(params, session) do
      {:ok, tenant_id, fleet_id, fleet_name, plan} ->
        socket = assign(socket,
          tenant_id: tenant_id,
          fleet_id: fleet_id,
          fleet_name: fleet_name,
          plan: plan,
          agents: %{},
          activities: [],
          usage: %{},
          # Navigation
          current_view: "dashboard",
          sidebar_collapsed: false,
          # Agent detail
          selected_agent: nil,
          agent_detail_open: false,
          agent_activities: [],
          # Messaging
          msg_to: nil,
          msg_body: "",
          msg_status: nil,
          messages: [],
          # Activity filter
          filter: "all",
          # Search
          search_query: "",
          search_open: false,
          # Toast
          toast: nil,
          # Sort
          sort_by: :name,
          sort_dir: :asc,
          # Auth
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
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("authenticate", %{"key" => key}, socket) do
    case validate_admin_key(key) do
      {:ok, tenant_id, fleet_id, fleet_name, plan} ->
        socket = assign(socket,
          tenant_id: tenant_id,
          fleet_id: fleet_id,
          fleet_name: fleet_name,
          plan: plan,
          agents: load_agents(fleet_id),
          activities: load_recent_activities(fleet_id),
          usage: load_usage(tenant_id),
          current_view: "dashboard",
          sidebar_collapsed: false,
          selected_agent: nil,
          agent_detail_open: false,
          agent_activities: [],
          msg_to: nil,
          msg_body: "",
          msg_status: nil,
          messages: [],
          filter: "all",
          search_query: "",
          search_open: false,
          toast: nil,
          sort_by: :name,
          sort_dir: :asc,
          authenticated: true,
          auth_error: nil
        )

        if connected?(socket) do
          Hub.Events.subscribe()
          Phoenix.PubSub.subscribe(Hub.PubSub, "fleet:#{socket.assigns.fleet_id}")
          Process.send_after(self(), :refresh_quota, 1_000)
        end

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, assign(socket, auth_error: "Invalid admin API key")}
    end
  end

  # Navigation
  def handle_event("navigate", %{"view" => view} = params, socket) do
    socket = assign(socket, current_view: view)

    # If navigating to agents with a specific agent selected
    socket = if view == "agents" && params["agent"] do
      assign(socket,
        selected_agent: params["agent"],
        agent_detail_open: true,
        agent_activities: filter_agent_activities(socket.assigns.activities, params["agent"])
      )
    else
      socket
    end

    # If navigating to messaging with a specific agent
    socket = if view == "messaging" && params["agent"] do
      agent_id = params["agent"]
      messages = load_conversation(socket.assigns.fleet_id, agent_id)
      assign(socket, msg_to: agent_id, messages: messages)
    else
      socket
    end

    {:noreply, socket}
  end

  def handle_event("toggle_sidebar", _, socket) do
    {:noreply, assign(socket, sidebar_collapsed: !socket.assigns.sidebar_collapsed)}
  end

  # Agent selection
  def handle_event("select_agent_detail", %{"agent-id" => agent_id}, socket) do
    agent_activities = filter_agent_activities(socket.assigns.activities, agent_id)
    {:noreply, assign(socket,
      selected_agent: agent_id,
      agent_detail_open: true,
      agent_activities: agent_activities
    )}
  end

  def handle_event("close_agent_detail", _, socket) do
    {:noreply, assign(socket, agent_detail_open: false)}
  end

  # Messaging
  def handle_event("select_msg_agent", %{"agent-id" => agent_id}, socket) do
    messages = load_conversation(socket.assigns.fleet_id, agent_id)
    {:noreply, assign(socket, msg_to: agent_id, messages: messages, msg_body: "")}
  end

  def handle_event("update_msg_body", %{"value" => value}, socket) do
    {:noreply, assign(socket, msg_body: value)}
  end

  def handle_event("send_message", %{"body" => body}, socket) do
    to = socket.assigns.msg_to
    fleet_id = socket.assigns.fleet_id

    if to && String.trim(body) != "" do
      case Hub.DirectMessage.send_message(fleet_id, "dashboard", to, %{"text" => body}) do
        {:ok, result} ->
          # Reload conversation
          messages = load_conversation(fleet_id, to)
          {:noreply, assign(socket,
            msg_body: "",
            messages: messages,
            toast: {:success, "Message #{result.status}"}
          )}

        {:error, reason} ->
          {:noreply, assign(socket, toast: {:error, "Failed: #{reason}"})}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("send_dm_from_detail", _, socket) do
    agent_id = socket.assigns.selected_agent
    messages = load_conversation(socket.assigns.fleet_id, agent_id)
    {:noreply, assign(socket,
      current_view: "messaging",
      msg_to: agent_id,
      messages: messages,
      agent_detail_open: false
    )}
  end

  # Activity filter
  def handle_event("set_filter", %{"filter" => filter}, socket) do
    {:noreply, assign(socket, filter: filter)}
  end

  # Search
  def handle_event("toggle_search", _, socket) do
    {:noreply, assign(socket, search_open: !socket.assigns.search_open, search_query: "")}
  end

  def handle_event("update_search", %{"value" => value}, socket) do
    {:noreply, assign(socket, search_query: value)}
  end

  # Sorting
  def handle_event("sort_agents", %{"column" => column}, socket) do
    col = String.to_existing_atom(column)
    dir = if socket.assigns.sort_by == col && socket.assigns.sort_dir == :asc, do: :desc, else: :asc
    {:noreply, assign(socket, sort_by: col, sort_dir: dir)}
  end

  # Toast
  def handle_event("clear_toast", _, socket) do
    {:noreply, assign(socket, toast: nil)}
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
    {:noreply, assign(socket, usage: usage, toast: {:warning, "Quota warning — check usage"})}
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
      render_app(assigns)
    else
      render_login(assigns)
    end
  end

  # ── Login Screen ───────────────────────────────────────────

  defp render_login(assigns) do
    ~H"""
    <div class="min-h-screen flex items-center justify-center bg-rf-bg bg-grid relative overflow-hidden">
      <div class="absolute inset-0 bg-radial-glow pointer-events-none"></div>
      <div class="absolute inset-0 pointer-events-none" style="background: radial-gradient(circle at 50% 50%, rgba(245,158,11,0.04) 0%, transparent 50%);"></div>

      <div class="relative z-10 glass-card rounded-2xl p-10 w-full max-w-md shadow-2xl fade-in-up" style="box-shadow: 0 0 60px rgba(245,158,11,0.06), 0 25px 50px rgba(0,0,0,0.4);">
        <div class="text-center mb-8">
          <div class="inline-flex items-center justify-center w-14 h-14 rounded-xl bg-gradient-to-br from-amber-500/20 to-amber-600/5 border border-amber-500/20 mb-5">
            <svg class="w-7 h-7 text-amber-400" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <polygon points="13 2 3 14 12 14 11 22 21 10 12 10 13 2"></polygon>
            </svg>
          </div>
          <h1 class="text-3xl font-bold tracking-tight">
            <span class="text-rf-text">RING</span><span class="text-amber-400">FORGE</span>
          </h1>
          <p class="text-rf-text-muted mt-2 text-xs uppercase tracking-[0.2em]">Agent Coordination Mesh</p>
        </div>

        <form phx-submit="authenticate" class="space-y-5">
          <div>
            <label class="text-xs text-rf-text-sec uppercase tracking-wider mb-2 block">Admin API Key</label>
            <input
              type="password"
              name="key"
              value={@key_input}
              placeholder="rf_admin_..."
              autocomplete="off"
              class="w-full px-4 py-3.5 bg-rf-bg/80 border border-rf-border rounded-xl text-rf-text placeholder-rf-text-muted focus:outline-none focus:border-amber-500/50 focus-glow font-mono text-sm transition-smooth"
            />
          </div>

          <%= if @auth_error do %>
            <div class="flex items-center justify-center gap-2 text-red-400 text-sm bg-red-500/10 border border-red-500/20 rounded-lg py-2 px-3 fade-in">
              <span>✕</span>
              <span><%= @auth_error %></span>
            </div>
          <% end %>

          <button
            type="submit"
            class="w-full py-3.5 bg-gradient-to-r from-amber-600 to-amber-500 hover:from-amber-500 hover:to-amber-400 text-gray-950 font-bold rounded-xl transition-smooth text-sm uppercase tracking-wider"
            style="box-shadow: 0 4px 14px rgba(245,158,11,0.25);"
          >
            Access Dashboard
          </button>
        </form>

        <div class="mt-6 text-center">
          <p class="text-rf-text-muted text-[10px] uppercase tracking-widest">Secured Access</p>
        </div>
      </div>
    </div>
    """
  end

  # ── Main App Shell ─────────────────────────────────────────

  defp render_app(assigns) do
    online_count = Enum.count(assigns.agents, fn {_id, m} -> m[:state] == "online" end)
    busy_count = Enum.count(assigns.agents, fn {_id, m} -> m[:state] == "busy" end)
    msg_used = get_in(assigns.usage, [:messages_today, :used]) || 0
    mem_info = Map.get(assigns.usage, :memory_entries, %{used: 0, limit: 0})
    mem_pct = Components.quota_percentage(mem_info)

    assigns = assign(assigns,
      online_count: online_count,
      busy_count: busy_count,
      msg_used: msg_used,
      mem_pct: mem_pct
    )

    ~H"""
    <div class="h-screen flex flex-col overflow-hidden bg-rf-bg bg-grid" id="app-shell">
      <%!-- Toast --%>
      <%= if @toast do %>
        <Components.toast type={elem(@toast, 0)} message={elem(@toast, 1)} />
      <% end %>

      <%!-- Top Bar --%>
      <header class="shrink-0 relative z-30" style="background: linear-gradient(180deg, rgba(17,17,25,0.97) 0%, rgba(10,10,15,0.99) 100%);">
        <div class="flex items-center justify-between px-5 py-3">
          <div class="flex items-center gap-4">
            <button phx-click="toggle_sidebar" class="w-8 h-8 rounded-lg flex items-center justify-center hover:bg-rf-card transition-smooth text-rf-text-muted hover:text-rf-text">
              <svg class="w-4 h-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round">
                <line x1="3" y1="6" x2="21" y2="6"></line>
                <line x1="3" y1="12" x2="21" y2="12"></line>
                <line x1="3" y1="18" x2="21" y2="18"></line>
              </svg>
            </button>
            <div class="flex items-center gap-2.5">
              <div class="w-8 h-8 rounded-lg bg-gradient-to-br from-amber-500/20 to-amber-600/5 border border-amber-500/20 flex items-center justify-center">
                <svg class="w-4 h-4 text-amber-400" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                  <polygon points="13 2 3 14 12 14 11 22 21 10 12 10 13 2"></polygon>
                </svg>
              </div>
              <div>
                <h1 class="text-base font-bold tracking-tight leading-none">
                  <span class="text-rf-text">RING</span><span class="text-amber-400">FORGE</span>
                </h1>
                <p class="text-[9px] text-rf-text-muted uppercase tracking-[0.25em] mt-0.5"><%= @fleet_name %></p>
              </div>
            </div>
          </div>

          <%!-- Quick stats --%>
          <div class="flex items-center gap-4">
            <div class="hidden md:flex items-center gap-5 text-xs">
              <div class="flex items-center gap-1.5 px-2.5 py-1 rounded-lg bg-rf-card/50 border border-rf-border/50">
                <span class="w-1.5 h-1.5 rounded-full bg-green-400"></span>
                <span class="text-rf-text-sec"><%= @online_count %></span>
                <span class="text-rf-text-muted">online</span>
              </div>
              <div class="flex items-center gap-1.5 px-2.5 py-1 rounded-lg bg-rf-card/50 border border-rf-border/50">
                <span class="text-rf-text-muted">💬</span>
                <span class="text-rf-text-sec"><%= Components.format_quota_number(@msg_used) %></span>
                <span class="text-rf-text-muted">msgs</span>
              </div>
              <div class="flex items-center gap-1.5 px-2.5 py-1 rounded-lg bg-rf-card/50 border border-rf-border/50">
                <span class="text-rf-text-muted">🧠</span>
                <span class="text-rf-text-sec"><%= @mem_pct %>%</span>
                <span class="text-rf-text-muted">mem</span>
              </div>
            </div>
            <div class="flex items-center gap-2 text-xs px-3 py-1.5 rounded-full border border-green-500/20 bg-green-500/5">
              <span class="inline-block w-2 h-2 rounded-full bg-green-400 pulse-dot" style="color: #22c55e;"></span>
              <span class="text-green-400 font-medium uppercase tracking-wider text-[10px]">Live</span>
            </div>
          </div>
        </div>
        <div class="h-px" style="background: linear-gradient(90deg, transparent 0%, rgba(245,158,11,0.3) 30%, rgba(245,158,11,0.5) 50%, rgba(245,158,11,0.3) 70%, transparent 100%);"></div>
      </header>

      <%!-- Main layout: sidebar + content --%>
      <div class="flex-1 flex min-h-0">
        <%!-- Sidebar --%>
        <nav class={"shrink-0 border-r border-rf-border overflow-y-auto transition-all duration-300 " <> if(@sidebar_collapsed, do: "w-0 opacity-0 overflow-hidden", else: "w-56")} style="background: linear-gradient(180deg, rgba(17,17,25,0.5) 0%, rgba(10,10,15,0.3) 100%);">
          <div class="p-3 space-y-1">
            <div class="px-3 py-2">
              <p class="text-[9px] font-semibold text-rf-text-muted uppercase tracking-[0.2em]">Navigation</p>
            </div>
            <Components.nav_item view="dashboard" icon="◈" label="Dashboard" active={@current_view == "dashboard"} />
            <Components.nav_item view="agents" icon="◎" label="Agents" active={@current_view == "agents"} badge={to_string(map_size(@agents))} />
            <Components.nav_item view="activity" icon="◉" label="Activity" active={@current_view == "activity"} badge={to_string(length(@activities))} />
            <Components.nav_item view="messaging" icon="◆" label="Messaging" active={@current_view == "messaging"} />
            <Components.nav_item view="quotas" icon="◧" label="Quotas" active={@current_view == "quotas"} />
            <Components.nav_item view="settings" icon="◎" label="Settings" active={@current_view == "settings"} />

            <%!-- Fleet info at bottom of sidebar --%>
            <div class="mt-6 pt-4 border-t border-rf-border/50">
              <div class="glass-card rounded-lg p-3">
                <div class="text-[9px] text-rf-text-muted uppercase tracking-wider mb-1">Plan</div>
                <div class="text-xs font-semibold text-amber-400 capitalize"><%= @plan %></div>
                <div class="text-[9px] text-rf-text-muted mt-1"><%= map_size(@agents) %> agents connected</div>
              </div>
            </div>
          </div>
        </nav>

        <%!-- Content Area --%>
        <main class="flex-1 min-w-0 overflow-hidden">
          <div class="h-full view-transition">
            <%= case @current_view do %>
              <% "dashboard" -> %>
                <%= render_overview(assigns) %>
              <% "agents" -> %>
                <%= render_agents(assigns) %>
              <% "activity" -> %>
                <%= render_activity(assigns) %>
              <% "messaging" -> %>
                <%= render_messaging(assigns) %>
              <% "quotas" -> %>
                <%= render_quotas(assigns) %>
              <% "settings" -> %>
                <%= render_settings(assigns) %>
              <% _ -> %>
                <%= render_overview(assigns) %>
            <% end %>
          </div>
        </main>
      </div>
    </div>
    """
  end

  # ── Page: Dashboard Overview ───────────────────────────────

  defp render_overview(assigns) do
    agents_sorted = assigns.agents
      |> Enum.sort_by(fn {_id, m} -> Components.state_sort_order(m[:state]) end)
      |> Enum.take(12)

    recent_activities = Enum.take(assigns.activities, 8)

    online_count = Enum.count(assigns.agents, fn {_id, m} -> m[:state] == "online" end)
    msg_info = Map.get(assigns.usage, :messages_today, %{used: 0, limit: 0})
    mem_info = Map.get(assigns.usage, :memory_entries, %{used: 0, limit: 0})

    assigns = assign(assigns,
      agents_sorted: agents_sorted,
      recent_activities: recent_activities,
      overview_online: online_count,
      msg_info: msg_info,
      mem_info: mem_info
    )

    ~H"""
    <div class="h-full overflow-y-auto p-6 space-y-6 fade-in">
      <%!-- Page header --%>
      <div class="flex items-center justify-between">
        <div>
          <h2 class="text-xl font-bold text-rf-text">Dashboard</h2>
          <p class="text-xs text-rf-text-muted mt-0.5">Fleet overview and real-time status</p>
        </div>
      </div>

      <%!-- Stat Cards --%>
      <div class="grid grid-cols-4 gap-4">
        <Components.stat_card label="Total Agents" value={to_string(map_size(@agents))} icon="◎" color="amber" />
        <Components.stat_card label="Online Now" value={to_string(@overview_online)} icon="◉" color="green" delta={"+" <> to_string(@overview_online)} delta_type={:positive} />
        <Components.stat_card label="Messages Today" value={Components.format_quota_number(@msg_info[:used] || 0)} icon="◆" color="blue" />
        <Components.stat_card label="Memory Used" value={to_string(Components.quota_percentage(@mem_info)) <> "%"} icon="◧" color="purple" />
      </div>

      <div class="grid grid-cols-[1fr_380px] gap-6">
        <%!-- Agent Grid --%>
        <div>
          <div class="flex items-center justify-between mb-4">
            <h3 class="text-sm font-semibold text-rf-text-sec uppercase tracking-wider">Active Agents</h3>
            <button phx-click="navigate" phx-value-view="agents" class="text-[10px] text-amber-400 hover:text-amber-300 transition-smooth uppercase tracking-wider">View All →</button>
          </div>
          <%= if map_size(@agents) == 0 do %>
            <Components.empty_state message="No agents connected" subtitle="Agents will appear here when they join the fleet" icon="◇" />
          <% else %>
            <div class="grid grid-cols-2 xl:grid-cols-3 gap-3">
              <%= for {agent_id, meta} <- @agents_sorted do %>
                <Components.agent_grid_card agent_id={agent_id} meta={meta} />
              <% end %>
            </div>
          <% end %>
        </div>

        <%!-- Right column: Activity + Quotas --%>
        <div class="space-y-6">
          <%!-- Mini Activity Feed --%>
          <div>
            <div class="flex items-center justify-between mb-3">
              <div class="flex items-center gap-2">
                <h3 class="text-sm font-semibold text-rf-text-sec uppercase tracking-wider">Recent Activity</h3>
                <span class="inline-block w-1.5 h-1.5 rounded-full bg-green-400 pulse-glow"></span>
              </div>
              <button phx-click="navigate" phx-value-view="activity" class="text-[10px] text-amber-400 hover:text-amber-300 transition-smooth uppercase tracking-wider">View All →</button>
            </div>
            <div class="space-y-1">
              <%= if @recent_activities == [] do %>
                <div class="glass-card rounded-lg p-6 text-center">
                  <p class="text-rf-text-muted text-xs">No activity yet</p>
                </div>
              <% else %>
                <%= for activity <- @recent_activities do %>
                  <Components.activity_item activity={activity} compact={true} />
                <% end %>
              <% end %>
            </div>
          </div>

          <%!-- Quota Overview --%>
          <div>
            <div class="flex items-center justify-between mb-3">
              <h3 class="text-sm font-semibold text-rf-text-sec uppercase tracking-wider">Quota Usage</h3>
              <button phx-click="navigate" phx-value-view="quotas" class="text-[10px] text-amber-400 hover:text-amber-300 transition-smooth uppercase tracking-wider">Details →</button>
            </div>
            <div class="glass-card rounded-xl p-4 space-y-4">
              <%= for {resource, label, icon, _color} <- Components.quota_resources() do %>
                <% info = Map.get(@usage, resource, %{used: 0, limit: 0}) %>
                <Components.quota_bar label={label} icon={icon} info={info} />
              <% end %>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── Page: Agents ───────────────────────────────────────────

  defp render_agents(assigns) do
    agents_list = assigns.agents
      |> Enum.map(fn {id, meta} -> {id, meta} end)
      |> maybe_filter_agents(assigns.search_query)
      |> sort_agents(assigns.sort_by, assigns.sort_dir)

    assigns = assign(assigns, agents_list: agents_list)

    ~H"""
    <div class="h-full flex">
      <%!-- Agent table --%>
      <div class={"flex-1 flex flex-col overflow-hidden transition-all duration-300 " <> if(@agent_detail_open, do: "mr-0", else: "")}>
        <%!-- Header bar --%>
        <div class="px-6 py-4 border-b border-rf-border shrink-0">
          <div class="flex items-center justify-between">
            <div>
              <h2 class="text-xl font-bold text-rf-text">Agents</h2>
              <p class="text-xs text-rf-text-muted mt-0.5"><%= map_size(@agents) %> registered · <%= Enum.count(@agents, fn {_,m} -> m[:state] == "online" end) %> online</p>
            </div>
            <div class="flex items-center gap-3">
              <%!-- Search --%>
              <div class="relative">
                <input
                  type="text"
                  placeholder="Search agents..."
                  value={@search_query}
                  phx-keyup="update_search"
                  class="w-64 px-3 py-2 pl-9 bg-rf-bg/80 border border-rf-border rounded-lg text-sm text-rf-text placeholder-rf-text-muted focus:outline-none focus:border-amber-500/50 focus-glow transition-smooth"
                />
                <svg class="w-4 h-4 absolute left-3 top-2.5 text-rf-text-muted" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                  <circle cx="11" cy="11" r="8"></circle>
                  <line x1="21" y1="21" x2="16.65" y2="16.65"></line>
                </svg>
              </div>
            </div>
          </div>
        </div>

        <%!-- Table --%>
        <div class="flex-1 overflow-auto">
          <%= if @agents_list == [] do %>
            <Components.empty_state message="No agents found" subtitle="Try adjusting your search or wait for agents to connect" icon="◎" />
          <% else %>
            <table class="w-full">
              <thead class="sticky top-0 z-10" style="background: rgba(10,10,15,0.95); backdrop-filter: blur(8px);">
                <tr class="border-b border-rf-border">
                  <th class="py-3 px-4 text-left">
                    <button phx-click="sort_agents" phx-value-column="name" class="text-[10px] font-semibold text-rf-text-muted uppercase tracking-wider hover:text-rf-text-sec transition-smooth flex items-center gap-1">
                      Name <%= sort_indicator(@sort_by, @sort_dir, :name) %>
                    </button>
                  </th>
                  <th class="py-3 px-4 text-left">
                    <button phx-click="sort_agents" phx-value-column="state" class="text-[10px] font-semibold text-rf-text-muted uppercase tracking-wider hover:text-rf-text-sec transition-smooth flex items-center gap-1">
                      State <%= sort_indicator(@sort_by, @sort_dir, :state) %>
                    </button>
                  </th>
                  <th class="py-3 px-4 text-left">
                    <span class="text-[10px] font-semibold text-rf-text-muted uppercase tracking-wider">Capabilities</span>
                  </th>
                  <th class="py-3 px-4 text-left">
                    <span class="text-[10px] font-semibold text-rf-text-muted uppercase tracking-wider">Current Task</span>
                  </th>
                  <th class="py-3 px-4 text-left">
                    <span class="text-[10px] font-semibold text-rf-text-muted uppercase tracking-wider">Connected</span>
                  </th>
                  <th class="py-3 px-4 text-left">
                    <button phx-click="sort_agents" phx-value-column="framework" class="text-[10px] font-semibold text-rf-text-muted uppercase tracking-wider hover:text-rf-text-sec transition-smooth flex items-center gap-1">
                      Framework <%= sort_indicator(@sort_by, @sort_dir, :framework) %>
                    </button>
                  </th>
                </tr>
              </thead>
              <tbody>
                <%= for {agent_id, meta} <- @agents_list do %>
                  <Components.agent_table_row agent_id={agent_id} meta={meta} selected={@selected_agent == agent_id} />
                <% end %>
              </tbody>
            </table>
          <% end %>
        </div>
      </div>

      <%!-- Agent Detail Slide-in Panel --%>
      <%= if @agent_detail_open do %>
        <% detail_meta = Map.get(@agents, @selected_agent, %{}) %>
        <div class="w-96 border-l border-rf-border overflow-y-auto shrink-0 slide-in-right" style="background: linear-gradient(180deg, rgba(17,17,25,0.8) 0%, rgba(10,10,15,0.6) 100%);">
          <div class="p-5">
            <%!-- Header --%>
            <div class="flex items-center justify-between mb-5">
              <h3 class="text-sm font-semibold text-rf-text uppercase tracking-wider">Agent Detail</h3>
              <button phx-click="close_agent_detail" class="w-7 h-7 rounded-lg flex items-center justify-center hover:bg-rf-card transition-smooth text-rf-text-muted hover:text-rf-text">
                <svg class="w-4 h-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round">
                  <line x1="18" y1="6" x2="6" y2="18"></line>
                  <line x1="6" y1="6" x2="18" y2="18"></line>
                </svg>
              </button>
            </div>

            <%!-- Agent info --%>
            <div class="glass-card rounded-xl p-4 mb-4">
              <div class="flex items-center gap-3 mb-3">
                <div class={"w-12 h-12 rounded-xl flex items-center justify-center text-lg font-bold " <> agent_avatar_bg(detail_meta[:state])}>
                  <%= agent_avatar_initial(detail_meta[:name] || @selected_agent) %>
                </div>
                <div>
                  <h4 class="text-base font-bold text-rf-text"><%= detail_meta[:name] || @selected_agent %></h4>
                  <div class="flex items-center gap-1.5 mt-0.5">
                    <span
                      class={"inline-block w-2 h-2 rounded-full " <> Components.state_color(detail_meta[:state])}
                      style={"color: " <> Components.state_dot_color(detail_meta[:state]) <> ";"}
                    ></span>
                    <span class={"text-xs font-medium " <> state_text_color(detail_meta[:state])}><%= detail_meta[:state] || "unknown" %></span>
                  </div>
                </div>
              </div>

              <div class="space-y-2.5 text-xs">
                <div class="flex items-center justify-between py-1.5 border-b border-rf-border/30">
                  <span class="text-rf-text-muted">Agent ID</span>
                  <span class="text-rf-text-sec font-mono text-[10px] truncate ml-4 max-w-[180px]"><%= @selected_agent %></span>
                </div>
                <div class="flex items-center justify-between py-1.5 border-b border-rf-border/30">
                  <span class="text-rf-text-muted">Framework</span>
                  <span class="text-rf-text-sec"><%= detail_meta[:framework] || "—" %></span>
                </div>
                <div class="flex items-center justify-between py-1.5 border-b border-rf-border/30">
                  <span class="text-rf-text-muted">Connected</span>
                  <span class="text-rf-text-sec font-mono"><%= format_connected_at(detail_meta[:connected_at]) %></span>
                </div>
                <div class="py-1.5 border-b border-rf-border/30">
                  <span class="text-rf-text-muted block mb-1.5">Current Task</span>
                  <span class="text-rf-text-sec"><%= detail_meta[:task] || "No active task" %></span>
                </div>
              </div>
            </div>

            <%!-- Capabilities --%>
            <div class="mb-4">
              <h4 class="text-[10px] font-semibold text-rf-text-muted uppercase tracking-wider mb-2">Capabilities</h4>
              <%= if detail_meta[:capabilities] && detail_meta[:capabilities] != [] do %>
                <div class="flex flex-wrap gap-1.5">
                  <%= for cap <- List.wrap(detail_meta[:capabilities]) do %>
                    <span class="text-[10px] px-2.5 py-1 rounded-lg bg-amber-500/10 text-amber-400 border border-amber-500/15 font-medium"><%= cap %></span>
                  <% end %>
                </div>
              <% else %>
                <p class="text-xs text-rf-text-muted italic">No capabilities registered</p>
              <% end %>
            </div>

            <%!-- Actions --%>
            <div class="mb-5">
              <button
                phx-click="send_dm_from_detail"
                class="w-full py-2.5 bg-gradient-to-r from-amber-600 to-amber-500 hover:from-amber-500 hover:to-amber-400 text-gray-950 font-bold rounded-lg text-xs transition-smooth uppercase tracking-wider"
                style="box-shadow: 0 2px 10px rgba(245,158,11,0.2);"
              >
                Send Message
              </button>
            </div>

            <%!-- Recent Activity --%>
            <div>
              <h4 class="text-[10px] font-semibold text-rf-text-muted uppercase tracking-wider mb-2">Recent Activity</h4>
              <%= if @agent_activities == [] do %>
                <p class="text-xs text-rf-text-muted italic">No recent activity</p>
              <% else %>
                <div class="space-y-1">
                  <%= for activity <- Enum.take(@agent_activities, 10) do %>
                    <Components.activity_item activity={activity} compact={true} />
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # ── Page: Activity ─────────────────────────────────────────

  defp render_activity(assigns) do
    filtered = filtered_activities(assigns.activities, assigns.filter)

    # Group by day
    {today_activities, yesterday_activities, older_activities} = group_by_day(filtered)

    assigns = assign(assigns,
      today_activities: today_activities,
      yesterday_activities: yesterday_activities,
      older_activities: older_activities,
      total_filtered: length(filtered)
    )

    ~H"""
    <div class="h-full flex flex-col overflow-hidden fade-in">
      <%!-- Header --%>
      <div class="px-6 py-4 border-b border-rf-border shrink-0">
        <div class="flex items-center justify-between">
          <div>
            <h2 class="text-xl font-bold text-rf-text">Activity</h2>
            <p class="text-xs text-rf-text-muted mt-0.5"><%= @total_filtered %> events</p>
          </div>
          <%!-- Filter chips --%>
          <div class="flex bg-rf-card rounded-lg p-0.5 border border-rf-border">
            <%= for {label, value} <- [{"All", "all"}, {"Tasks", "tasks"}, {"Discoveries", "discoveries"}, {"Alerts", "alerts"}, {"Joins/Leaves", "joins"}] do %>
              <button
                phx-click="set_filter"
                phx-value-filter={value}
                class={"text-[10px] px-3 py-1.5 rounded-md font-medium transition-smooth uppercase tracking-wider " <> if(@filter == value, do: "bg-amber-500/15 text-amber-400 shadow-sm", else: "text-rf-text-muted hover:text-rf-text-sec")}
              >
                <%= label %>
              </button>
            <% end %>
          </div>
        </div>
      </div>

      <%!-- Activity stream --%>
      <div class="flex-1 overflow-y-auto px-6 py-4" id="activity-stream">
        <%= if @total_filtered == 0 do %>
          <Components.empty_state message="No events match your filter" subtitle="Try selecting a different filter or wait for new events" icon="◈" />
        <% else %>
          <%!-- Today --%>
          <%= if @today_activities != [] do %>
            <div class="mb-6">
              <div class="flex items-center gap-3 mb-3">
                <h3 class="text-xs font-semibold text-rf-text-sec uppercase tracking-wider">Today</h3>
                <div class="flex-1 h-px bg-rf-border/50"></div>
                <span class="text-[10px] text-rf-text-muted font-mono"><%= length(@today_activities) %></span>
              </div>
              <div class="space-y-1">
                <%= for activity <- @today_activities do %>
                  <Components.activity_item activity={activity} />
                <% end %>
              </div>
            </div>
          <% end %>

          <%!-- Yesterday --%>
          <%= if @yesterday_activities != [] do %>
            <div class="mb-6">
              <div class="flex items-center gap-3 mb-3">
                <h3 class="text-xs font-semibold text-rf-text-sec uppercase tracking-wider">Yesterday</h3>
                <div class="flex-1 h-px bg-rf-border/50"></div>
                <span class="text-[10px] text-rf-text-muted font-mono"><%= length(@yesterday_activities) %></span>
              </div>
              <div class="space-y-1">
                <%= for activity <- @yesterday_activities do %>
                  <Components.activity_item activity={activity} />
                <% end %>
              </div>
            </div>
          <% end %>

          <%!-- Older --%>
          <%= if @older_activities != [] do %>
            <div class="mb-6">
              <div class="flex items-center gap-3 mb-3">
                <h3 class="text-xs font-semibold text-rf-text-sec uppercase tracking-wider">Older</h3>
                <div class="flex-1 h-px bg-rf-border/50"></div>
                <span class="text-[10px] text-rf-text-muted font-mono"><%= length(@older_activities) %></span>
              </div>
              <div class="space-y-1">
                <%= for activity <- @older_activities do %>
                  <Components.activity_item activity={activity} />
                <% end %>
              </div>
            </div>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  # ── Page: Messaging ────────────────────────────────────────

  defp render_messaging(assigns) do
    agents_sorted = assigns.agents
      |> Enum.sort_by(fn {_id, m} -> Components.state_sort_order(m[:state]) end)

    assigns = assign(assigns, agents_sorted: agents_sorted)

    ~H"""
    <div class="h-full flex fade-in">
      <%!-- Agent list sidebar --%>
      <div class="w-64 border-r border-rf-border overflow-y-auto shrink-0" style="background: linear-gradient(180deg, rgba(17,17,25,0.4) 0%, rgba(10,10,15,0.2) 100%);">
        <div class="p-3">
          <h3 class="text-[10px] font-semibold text-rf-text-muted uppercase tracking-[0.15em] px-2 py-2">Agents</h3>
          <%= if map_size(@agents) == 0 do %>
            <div class="px-2 py-4 text-center">
              <p class="text-xs text-rf-text-muted">No agents online</p>
            </div>
          <% else %>
            <div class="space-y-0.5">
              <%= for {agent_id, meta} <- @agents_sorted do %>
                <button
                  phx-click="select_msg_agent"
                  phx-value-agent-id={agent_id}
                  class={"w-full flex items-center gap-2.5 px-3 py-2.5 rounded-lg transition-all duration-150 text-left " <> if(@msg_to == agent_id, do: "bg-amber-500/10 border border-amber-500/15", else: "hover:bg-rf-card/50")}
                >
                  <span
                    class={"inline-block w-2 h-2 rounded-full shrink-0 " <> Components.state_color(meta[:state])}
                    style={"color: " <> Components.state_dot_color(meta[:state]) <> ";"}
                  ></span>
                  <div class="min-w-0 flex-1">
                    <span class="text-sm font-medium text-rf-text truncate block"><%= meta[:name] || agent_id %></span>
                    <span class="text-[10px] text-rf-text-muted"><%= meta[:state] || "unknown" %></span>
                  </div>
                </button>
              <% end %>
            </div>
          <% end %>
        </div>
      </div>

      <%!-- Conversation area --%>
      <div class="flex-1 flex flex-col min-w-0">
        <%= if @msg_to do %>
          <% agent_meta = Map.get(@agents, @msg_to, %{name: @msg_to}) %>
          <%!-- Conversation header --%>
          <div class="px-5 py-3 border-b border-rf-border shrink-0 flex items-center gap-3">
            <div class={"w-8 h-8 rounded-lg flex items-center justify-center text-sm font-bold " <> agent_avatar_bg(agent_meta[:state])}>
              <%= agent_avatar_initial(agent_meta[:name] || @msg_to) %>
            </div>
            <div>
              <h3 class="text-sm font-semibold text-rf-text"><%= agent_meta[:name] || @msg_to %></h3>
              <span class="text-[10px] text-rf-text-muted"><%= agent_meta[:state] || "offline" %></span>
            </div>
          </div>

          <%!-- Messages --%>
          <div class="flex-1 overflow-y-auto px-5 py-4" id="message-thread">
            <%= if @messages == [] do %>
              <div class="flex flex-col items-center justify-center h-full text-center">
                <div class="text-3xl mb-3 opacity-20">◆</div>
                <p class="text-rf-text-muted text-xs">No messages yet</p>
                <p class="text-rf-text-muted/50 text-[10px] mt-1">Send the first message below</p>
              </div>
            <% else %>
              <%= for msg <- @messages do %>
                <Components.message_bubble msg={msg} />
              <% end %>
            <% end %>
          </div>

          <%!-- Message input --%>
          <div class="px-5 py-3 border-t border-rf-border shrink-0">
            <form phx-submit="send_message" class="flex gap-3">
              <input type="hidden" name="to" value={@msg_to} />
              <input
                type="text"
                name="body"
                value={@msg_body}
                phx-keyup="update_msg_body"
                placeholder={"Message " <> (agent_meta[:name] || @msg_to) <> "..."}
                autocomplete="off"
                class="flex-1 px-4 py-2.5 bg-rf-bg/80 border border-rf-border rounded-lg text-sm text-rf-text placeholder-rf-text-muted focus:outline-none focus:border-amber-500/50 focus-glow transition-smooth"
              />
              <button
                type="submit"
                class="px-5 py-2.5 bg-gradient-to-r from-amber-600 to-amber-500 hover:from-amber-500 hover:to-amber-400 text-gray-950 font-bold rounded-lg text-xs transition-smooth uppercase tracking-wider shrink-0"
                style="box-shadow: 0 2px 10px rgba(245,158,11,0.2);"
              >
                Send
              </button>
            </form>
          </div>
        <% else %>
          <%!-- No agent selected --%>
          <div class="flex-1 flex items-center justify-center">
            <div class="text-center">
              <div class="text-4xl mb-4 opacity-20">◆</div>
              <p class="text-rf-text-muted text-sm">Select an agent to start messaging</p>
              <p class="text-rf-text-muted/50 text-xs mt-1">Choose from the list on the left</p>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # ── Page: Quotas & Metrics ─────────────────────────────────

  defp render_quotas(assigns) do
    plan_limits = Hub.Quota.plan_limits()
    current_limits = Map.get(plan_limits, assigns.plan, %{})

    assigns = assign(assigns,
      current_limits: current_limits,
      plan_limits: plan_limits
    )

    ~H"""
    <div class="h-full overflow-y-auto p-6 fade-in">
      <div class="max-w-4xl">
        <%!-- Header --%>
        <div class="mb-6">
          <h2 class="text-xl font-bold text-rf-text">Quotas & Metrics</h2>
          <p class="text-xs text-rf-text-muted mt-0.5">Resource usage and plan limits</p>
        </div>

        <%!-- Plan Info Card --%>
        <div class="glass-card rounded-xl p-5 mb-6">
          <div class="flex items-center justify-between">
            <div class="flex items-center gap-4">
              <div class="w-12 h-12 rounded-xl bg-gradient-to-br from-amber-500/20 to-amber-600/5 border border-amber-500/20 flex items-center justify-center">
                <svg class="w-6 h-6 text-amber-400" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                  <polygon points="13 2 3 14 12 14 11 22 21 10 12 10 13 2"></polygon>
                </svg>
              </div>
              <div>
                <h3 class="text-lg font-bold text-rf-text capitalize"><%= @plan %> Plan</h3>
                <p class="text-xs text-rf-text-muted">Tenant: <%= String.slice(@tenant_id, 0, 8) %>...</p>
              </div>
            </div>
            <div class="text-right">
              <div class="text-[10px] text-rf-text-muted uppercase tracking-wider">Fleet</div>
              <div class="text-sm font-semibold text-rf-text"><%= @fleet_name %></div>
            </div>
          </div>
        </div>

        <%!-- Quota Cards Grid --%>
        <div class="grid grid-cols-2 gap-4 mb-6">
          <%= for {resource, label, icon, color} <- Components.quota_resources() do %>
            <% info = Map.get(@usage, resource, %{used: 0, limit: 0}) %>
            <Components.quota_card label={label} icon={icon} info={info} color={color} />
          <% end %>
        </div>

        <%!-- Plan Comparison --%>
        <div class="glass-card rounded-xl p-5 mb-6">
          <h3 class="text-sm font-semibold text-rf-text mb-4">Plan Limits Comparison</h3>
          <div class="overflow-x-auto">
            <table class="w-full text-xs">
              <thead>
                <tr class="border-b border-rf-border">
                  <th class="py-2 px-3 text-left text-rf-text-muted uppercase tracking-wider text-[10px]">Resource</th>
                  <%= for plan_name <- ["free", "team", "enterprise"] do %>
                    <th class={"py-2 px-3 text-center text-[10px] uppercase tracking-wider " <> if(@plan == plan_name, do: "text-amber-400", else: "text-rf-text-muted")}>
                      <%= plan_name %>
                      <%= if @plan == plan_name do %>
                        <span class="ml-1 text-[8px] px-1.5 py-0.5 rounded-full bg-amber-500/15">current</span>
                      <% end %>
                    </th>
                  <% end %>
                </tr>
              </thead>
              <tbody>
                <%= for {resource, label, _icon, _color} <- Components.quota_resources() do %>
                  <tr class="border-b border-rf-border/30">
                    <td class="py-2.5 px-3 text-rf-text-sec"><%= label %></td>
                    <%= for plan_name <- ["free", "team", "enterprise"] do %>
                      <% limits = Map.get(@plan_limits, plan_name, %{}) %>
                      <% val = Map.get(limits, resource) %>
                      <td class={"py-2.5 px-3 text-center font-mono " <> if(@plan == plan_name, do: "text-amber-400", else: "text-rf-text-sec")}>
                        <%= Components.format_quota_limit(val || 0) %>
                      </td>
                    <% end %>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>

        <%!-- Usage Over Time placeholder --%>
        <div class="glass-card rounded-xl p-5">
          <div class="flex items-center justify-between mb-4">
            <h3 class="text-sm font-semibold text-rf-text">Usage Over Time</h3>
            <span class="text-[10px] px-2.5 py-1 rounded-full bg-rf-border text-rf-text-muted font-medium">Coming Soon</span>
          </div>
          <div class="h-32 flex items-center justify-center border border-rf-border/30 rounded-lg border-dashed">
            <div class="text-center">
              <div class="text-2xl mb-2 opacity-20">📊</div>
              <p class="text-[10px] text-rf-text-muted uppercase tracking-wider">Historical charts will appear here</p>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── Page: Settings ─────────────────────────────────────────

  defp render_settings(assigns) do
    ~H"""
    <div class="h-full overflow-y-auto p-6 fade-in">
      <div class="max-w-2xl">
        <div class="mb-6">
          <h2 class="text-xl font-bold text-rf-text">Settings</h2>
          <p class="text-xs text-rf-text-muted mt-0.5">Fleet configuration and preferences</p>
        </div>

        <%!-- Fleet Info --%>
        <div class="glass-card rounded-xl p-5 mb-4">
          <h3 class="text-sm font-semibold text-rf-text mb-4">Fleet Information</h3>
          <div class="space-y-3 text-xs">
            <div class="flex items-center justify-between py-2 border-b border-rf-border/30">
              <span class="text-rf-text-muted">Fleet Name</span>
              <span class="text-rf-text font-medium"><%= @fleet_name %></span>
            </div>
            <div class="flex items-center justify-between py-2 border-b border-rf-border/30">
              <span class="text-rf-text-muted">Fleet ID</span>
              <span class="text-rf-text-sec font-mono text-[10px]"><%= @fleet_id %></span>
            </div>
            <div class="flex items-center justify-between py-2 border-b border-rf-border/30">
              <span class="text-rf-text-muted">Tenant ID</span>
              <span class="text-rf-text-sec font-mono text-[10px]"><%= @tenant_id %></span>
            </div>
            <div class="flex items-center justify-between py-2 border-b border-rf-border/30">
              <span class="text-rf-text-muted">Plan</span>
              <span class="text-amber-400 font-medium capitalize"><%= @plan %></span>
            </div>
            <div class="flex items-center justify-between py-2">
              <span class="text-rf-text-muted">Connected Agents</span>
              <span class="text-rf-text font-medium"><%= map_size(@agents) %></span>
            </div>
          </div>
        </div>

        <%!-- Connection Info --%>
        <div class="glass-card rounded-xl p-5 mb-4">
          <h3 class="text-sm font-semibold text-rf-text mb-4">Connection</h3>
          <div class="space-y-3 text-xs">
            <div class="flex items-center justify-between py-2 border-b border-rf-border/30">
              <span class="text-rf-text-muted">WebSocket</span>
              <div class="flex items-center gap-1.5">
                <span class="w-2 h-2 rounded-full bg-green-400 pulse-dot" style="color: #22c55e;"></span>
                <span class="text-green-400 font-medium">Connected</span>
              </div>
            </div>
            <div class="flex items-center justify-between py-2 border-b border-rf-border/30">
              <span class="text-rf-text-muted">PubSub Topic</span>
              <span class="text-rf-text-sec font-mono text-[10px]">fleet:<%= @fleet_id %></span>
            </div>
            <div class="flex items-center justify-between py-2">
              <span class="text-rf-text-muted">Quota Refresh</span>
              <span class="text-rf-text-sec">Every 5s</span>
            </div>
          </div>
        </div>

        <%!-- Keyboard Shortcuts --%>
        <div class="glass-card rounded-xl p-5">
          <h3 class="text-sm font-semibold text-rf-text mb-4">Keyboard Shortcuts</h3>
          <div class="grid grid-cols-2 gap-2 text-xs">
            <%= for {key, desc} <- [{"1", "Dashboard"}, {"2", "Agents"}, {"3", "Activity"}, {"4", "Messaging"}, {"5", "Quotas"}, {"6", "Settings"}] do %>
              <div class="flex items-center gap-2 py-1.5">
                <kbd class="px-2 py-1 rounded bg-rf-border text-rf-text-sec text-[10px] font-mono border border-rf-border-bright/50"><%= key %></kbd>
                <span class="text-rf-text-muted"><%= desc %></span>
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
        tenant = Hub.Repo.get(Hub.Auth.Tenant, tenant_id)
        plan = if tenant, do: tenant.plan || "free", else: "free"
        if fleet, do: {:ok, tenant_id, fleet.id, fleet.name, plan}, else: {:error, :unauthenticated}

      true ->
        {:error, :unauthenticated}
    end
  end

  defp validate_admin_key(raw_key) do
    case Hub.Auth.validate_api_key(raw_key) do
      {:ok, %{type: "admin", tenant_id: tenant_id}} ->
        fleet = load_default_fleet(tenant_id)
        tenant = Hub.Repo.get(Hub.Auth.Tenant, tenant_id)
        plan = if tenant, do: tenant.plan || "free", else: "free"
        if fleet do
          {:ok, tenant_id, fleet.id, fleet.name, plan}
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

  defp load_conversation(fleet_id, agent_id) do
    case Hub.DirectMessage.history(fleet_id, "dashboard", agent_id, limit: 50) do
      {:ok, messages} -> messages
      {:error, _} -> []
    end
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

  defp filtered_activities(activities, "joins") do
    Enum.filter(activities, fn a -> a.kind in ~w(join leave) end)
  end

  defp filtered_activities(activities, _), do: activities

  defp filter_agent_activities(activities, agent_id) do
    Enum.filter(activities, fn a -> a.agent_id == agent_id end)
  end

  defp group_by_day(activities) do
    today = Date.utc_today()
    yesterday = Date.add(today, -1)

    Enum.reduce(activities, {[], [], []}, fn activity, {t, y, o} ->
      case parse_date(activity.timestamp) do
        ^today -> {t ++ [activity], y, o}
        ^yesterday -> {t, y ++ [activity], o}
        _ -> {t, y, o ++ [activity]}
      end
    end)
  end

  defp parse_date(nil), do: nil
  defp parse_date(""), do: nil
  defp parse_date(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> DateTime.to_date(dt)
      _ -> nil
    end
  end
  defp parse_date(_), do: nil

  defp maybe_filter_agents(agents, ""), do: agents
  defp maybe_filter_agents(agents, nil), do: agents
  defp maybe_filter_agents(agents, query) do
    q = String.downcase(query)
    Enum.filter(agents, fn {id, meta} ->
      String.contains?(String.downcase(id), q) ||
      String.contains?(String.downcase(meta[:name] || ""), q) ||
      String.contains?(String.downcase(meta[:framework] || ""), q) ||
      Enum.any?(List.wrap(meta[:capabilities] || []), fn c ->
        String.contains?(String.downcase(c), q)
      end)
    end)
  end

  defp sort_agents(agents, :name, dir) do
    Enum.sort_by(agents, fn {_id, m} -> String.downcase(m[:name] || "") end, dir_fun(dir))
  end
  defp sort_agents(agents, :state, dir) do
    Enum.sort_by(agents, fn {_id, m} -> Components.state_sort_order(m[:state]) end, dir_fun(dir))
  end
  defp sort_agents(agents, :framework, dir) do
    Enum.sort_by(agents, fn {_id, m} -> String.downcase(m[:framework] || "zzz") end, dir_fun(dir))
  end
  defp sort_agents(agents, _, _dir), do: agents

  defp dir_fun(:asc), do: :asc
  defp dir_fun(:desc), do: :desc

  defp sort_indicator(current_col, dir, col) when current_col == col do
    if dir == :asc, do: "↑", else: "↓"
  end
  defp sort_indicator(_, _, _), do: ""

  defp format_connected_at(nil), do: "—"
  defp format_connected_at(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%H:%M")
      _ -> "—"
    end
  end
  defp format_connected_at(_), do: "—"

  defp state_text_color("online"), do: "text-green-400"
  defp state_text_color("busy"), do: "text-yellow-400"
  defp state_text_color("away"), do: "text-gray-400"
  defp state_text_color("offline"), do: "text-red-400"
  defp state_text_color(_), do: "text-gray-500"

  defp agent_avatar_bg("online"), do: "bg-gradient-to-br from-green-500/20 to-green-600/5 border border-green-500/20 text-green-400"
  defp agent_avatar_bg("busy"), do: "bg-gradient-to-br from-yellow-500/20 to-yellow-600/5 border border-yellow-500/20 text-yellow-400"
  defp agent_avatar_bg("away"), do: "bg-gradient-to-br from-gray-500/20 to-gray-600/5 border border-gray-500/20 text-gray-400"
  defp agent_avatar_bg("offline"), do: "bg-gradient-to-br from-red-500/20 to-red-600/5 border border-red-500/20 text-red-400"
  defp agent_avatar_bg(_), do: "bg-gradient-to-br from-gray-500/20 to-gray-600/5 border border-gray-500/20 text-gray-500"

  defp agent_avatar_initial(nil), do: "?"
  defp agent_avatar_initial(""), do: "?"
  defp agent_avatar_initial(name) do
    name |> String.trim() |> String.first() |> String.upcase()
  end
end
