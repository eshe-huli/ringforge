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
    <div class="min-h-screen flex items-center justify-center bg-rf-bg bg-grid relative overflow-hidden">
      <%!-- Radial glow behind card --%>
      <div class="absolute inset-0 bg-radial-glow pointer-events-none"></div>
      <div class="absolute inset-0 pointer-events-none" style="background: radial-gradient(circle at 50% 50%, rgba(245,158,11,0.04) 0%, transparent 50%);"></div>

      <div class="relative z-10 glass-card rounded-2xl p-10 w-full max-w-md shadow-2xl fade-in-up" style="box-shadow: 0 0 60px rgba(245,158,11,0.06), 0 25px 50px rgba(0,0,0,0.4);">
        <div class="text-center mb-8">
          <%!-- Logo mark --%>
          <div class="inline-flex items-center justify-center w-14 h-14 rounded-xl bg-gradient-to-br from-amber-500/20 to-amber-600/5 border border-amber-500/20 mb-5">
            <span class="text-2xl font-bold text-amber-400">⚡</span>
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
            ⚡ Access Dashboard
          </button>
        </form>

        <div class="mt-6 text-center">
          <p class="text-rf-text-muted text-[10px] uppercase tracking-widest">Secured Access</p>
        </div>
      </div>
    </div>
    """
  end

  defp render_dashboard(assigns) do
    agents_sorted = assigns.agents
      |> Enum.sort_by(fn {_id, m} -> state_sort_order(m[:state]) end)

    filtered = filtered_activities(assigns.activities, assigns.filter)

    # Fleet status summary counts
    agent_states = Enum.map(assigns.agents, fn {_id, m} -> m[:state] || "unknown" end)
    online_count = Enum.count(agent_states, &(&1 == "online"))
    busy_count = Enum.count(agent_states, &(&1 == "busy"))
    offline_count = Enum.count(agent_states, &(&1 in ["offline", "away"]))

    assigns = assign(assigns,
      agents_sorted: agents_sorted,
      filtered_activities: filtered,
      online_count: online_count,
      busy_count: busy_count,
      offline_count: offline_count
    )

    ~H"""
    <div class="h-screen flex flex-col overflow-hidden bg-rf-bg bg-grid">
      <%!-- Header --%>
      <header class="shrink-0 relative" style="background: linear-gradient(180deg, rgba(17,17,25,0.95) 0%, rgba(10,10,15,0.98) 100%);">
        <div class="flex items-center justify-between px-6 py-3.5">
          <div class="flex items-center gap-4">
            <%!-- Logo --%>
            <div class="flex items-center gap-2.5">
              <div class="w-8 h-8 rounded-lg bg-gradient-to-br from-amber-500/20 to-amber-600/5 border border-amber-500/20 flex items-center justify-center">
                <span class="text-amber-400 text-sm font-bold">⚡</span>
              </div>
              <div>
                <h1 class="text-base font-bold tracking-tight leading-none">
                  <span class="text-rf-text">RING</span><span class="text-amber-400">FORGE</span>
                </h1>
                <p class="text-[9px] text-rf-text-muted uppercase tracking-[0.25em] mt-0.5">Agent Coordination Mesh</p>
              </div>
            </div>
          </div>
          <div class="flex items-center gap-5">
            <span class="text-xs text-rf-text-muted">
              Fleet: <span class="text-rf-text-sec font-medium"><%= @fleet_name %></span>
            </span>
            <div class="flex items-center gap-2 text-xs px-3 py-1.5 rounded-full border border-green-500/20 bg-green-500/5">
              <span class="inline-block w-2 h-2 rounded-full bg-green-400 pulse-dot" style="color: #22c55e;"></span>
              <span class="text-green-400 font-medium uppercase tracking-wider text-[10px]">Live</span>
            </div>
          </div>
        </div>
        <%!-- Gradient border bottom --%>
        <div class="h-px" style="background: linear-gradient(90deg, transparent 0%, rgba(245,158,11,0.3) 30%, rgba(245,158,11,0.5) 50%, rgba(245,158,11,0.3) 70%, transparent 100%);"></div>
      </header>

      <%!-- Main grid --%>
      <div class="flex-1 grid grid-cols-[300px_1fr] min-h-0">

        <%!-- Left sidebar --%>
        <div class="border-r border-rf-border overflow-y-auto" style="background: linear-gradient(180deg, rgba(17,17,25,0.5) 0%, rgba(10,10,15,0.3) 100%);">
          <div class="p-4">

            <%!-- Fleet Status Summary --%>
            <div class="glass-card rounded-xl p-3.5 mb-4">
              <h2 class="text-[10px] font-semibold text-rf-text-muted uppercase tracking-[0.15em] mb-3">Fleet Status</h2>
              <div class="flex items-center gap-4 text-xs">
                <div class="flex items-center gap-1.5">
                  <span class="inline-block w-2 h-2 rounded-full bg-green-400"></span>
                  <span class="text-rf-text-sec"><%= @online_count %> online</span>
                </div>
                <div class="flex items-center gap-1.5">
                  <span class="inline-block w-2 h-2 rounded-full bg-yellow-400"></span>
                  <span class="text-rf-text-sec"><%= @busy_count %> busy</span>
                </div>
                <div class="flex items-center gap-1.5">
                  <span class="inline-block w-2 h-2 rounded-full bg-rf-text-muted"></span>
                  <span class="text-rf-text-sec"><%= @offline_count %> offline</span>
                </div>
              </div>
            </div>

            <%!-- Agent label --%>
            <div class="flex items-center justify-between mb-3">
              <h2 class="text-[10px] font-semibold text-rf-text-muted uppercase tracking-[0.15em]">Agents</h2>
              <span class="text-[10px] font-mono text-amber-400/70"><%= map_size(@agents) %></span>
            </div>

            <%!-- Empty state --%>
            <%= if map_size(@agents) == 0 do %>
              <div class="glass-card rounded-xl p-6 text-center">
                <div class="text-2xl mb-3 float-subtle">◇</div>
                <p class="text-rf-text-muted text-xs">Waiting for agents to connect...</p>
                <div class="mt-3 h-px shimmer rounded"></div>
              </div>
            <% end %>

            <%!-- Agent Cards --%>
            <%= for {agent_id, meta} <- @agents_sorted do %>
              <div
                phx-click="select_agent"
                phx-value-agent-id={agent_id}
                class={"glass-card rounded-xl p-3.5 mb-2.5 cursor-pointer transition-smooth " <> if(@selected_agent == agent_id, do: "border-glow !border-amber-500/40", else: "")}
                style={if @selected_agent == agent_id, do: "box-shadow: 0 0 20px rgba(245,158,11,0.08);", else: ""}
              >
                <div class="flex items-center gap-2.5">
                  <span
                    class={"inline-block w-2.5 h-2.5 rounded-full shrink-0 " <> state_color(meta[:state]) <> if(meta[:state] in ["online", "busy"], do: " pulse-dot", else: "")}
                    style={"color: " <> state_dot_color(meta[:state]) <> ";"}
                  ></span>
                  <span class="font-semibold text-sm text-rf-text truncate"><%= meta[:name] || agent_id %></span>
                  <span class={"ml-auto text-[10px] px-2 py-0.5 rounded-full font-medium " <> state_badge(meta[:state])}>
                    <%= meta[:state] || "unknown" %>
                  </span>
                </div>
                <%= if meta[:task] do %>
                  <div class="mt-2 ml-5 text-xs text-rf-text-sec truncate flex items-center gap-1.5" title={meta[:task]}>
                    <span class="text-rf-text-muted">▸</span>
                    <span><%= meta[:task] %></span>
                  </div>
                <% end %>
                <%= if meta[:capabilities] && meta[:capabilities] != [] do %>
                  <div class="flex flex-wrap gap-1.5 mt-2.5 ml-5">
                    <%= for cap <- Enum.take(List.wrap(meta[:capabilities]), 5) do %>
                      <span class="text-[10px] px-2 py-0.5 rounded-full bg-rf-border text-rf-text-sec border border-rf-border-bright/50"><%= cap %></span>
                    <% end %>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
        </div>

        <%!-- Right content area --%>
        <div class="flex flex-col min-h-0 overflow-hidden">

          <%!-- Activity Feed --%>
          <div class="flex-1 flex flex-col overflow-hidden">
            <div class="px-5 py-3 flex items-center justify-between shrink-0 border-b border-rf-border">
              <div class="flex items-center gap-2.5">
                <h2 class="text-[10px] font-semibold text-rf-text-muted uppercase tracking-[0.15em]">Live Activity</h2>
                <span class="inline-block w-1.5 h-1.5 rounded-full bg-green-400 pulse-glow" style="color: #22c55e;"></span>
              </div>
              <%!-- Segment control filter --%>
              <div class="flex bg-rf-card rounded-lg p-0.5 border border-rf-border">
                <%= for {label, value} <- [{"All", "all"}, {"Tasks", "tasks"}, {"Discoveries", "discoveries"}, {"Alerts", "alerts"}] do %>
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

            <div class="flex-1 overflow-y-auto px-5 py-3 space-y-1.5" id="activity-feed">
              <%= if @filtered_activities == [] do %>
                <div class="flex flex-col items-center justify-center py-16 text-center">
                  <div class="text-3xl mb-4 float-subtle opacity-30">◈</div>
                  <p class="text-rf-text-muted text-xs uppercase tracking-wider">No activity yet</p>
                  <p class="text-rf-text-muted/50 text-[10px] mt-1">Events will appear here in real-time</p>
                </div>
              <% end %>

              <%= for activity <- @filtered_activities do %>
                <div class={"fade-in accent-bar pl-4 py-2.5 pr-3 rounded-lg hover:bg-rf-card/50 group transition-smooth " <> kind_color(activity.kind)}>
                  <div class="flex items-start gap-3">
                    <span class="text-[10px] text-rf-text-muted whitespace-nowrap mt-0.5 font-mono">
                      <%= format_time(activity.timestamp) %>
                    </span>
                    <span class="text-sm mt-px"><%= kind_icon(activity.kind) %></span>
                    <div class="min-w-0 flex-1">
                      <div class="flex items-center gap-2">
                        <span class="text-sm font-semibold text-rf-text"><%= activity.agent_name %></span>
                        <span class={"text-[10px] px-2 py-0.5 rounded-full font-medium " <> kind_badge_style(activity.kind)}>
                          <%= activity.kind %>
                        </span>
                      </div>
                      <div class="text-xs text-rf-text-sec mt-0.5 truncate"><%= activity.description %></div>
                    </div>
                  </div>
                </div>
              <% end %>
            </div>
          </div>

          <%!-- Bottom panels --%>
          <div class="shrink-0 border-t border-rf-border grid grid-cols-[1fr_1fr]" style="height: 220px;">

            <%!-- Send Message --%>
            <div class="p-4 border-r border-rf-border overflow-y-auto">
              <h2 class="text-[10px] font-semibold text-rf-text-muted uppercase tracking-[0.15em] mb-3">Send Message</h2>
              <form phx-submit="send_message" class="space-y-2.5">
                <div>
                  <label class="text-[10px] text-rf-text-muted uppercase tracking-wider mb-1 block">To</label>
                  <input
                    type="text"
                    name="to"
                    value={@msg_to}
                    phx-keyup="update_msg_to"
                    placeholder="agent_id"
                    class="w-full px-3 py-2.5 bg-rf-bg/80 border border-rf-border rounded-lg text-sm text-rf-text placeholder-rf-text-muted focus:outline-none focus:border-amber-500/50 focus-glow font-mono transition-smooth"
                  />
                </div>
                <div>
                  <label class="text-[10px] text-rf-text-muted uppercase tracking-wider mb-1 block">Message</label>
                  <textarea
                    name="body"
                    phx-keyup="update_msg_body"
                    placeholder="Type a message..."
                    rows="2"
                    class="w-full px-3 py-2.5 bg-rf-bg/80 border border-rf-border rounded-lg text-sm text-rf-text placeholder-rf-text-muted focus:outline-none focus:border-amber-500/50 focus-glow font-mono resize-none transition-smooth"
                  ><%= @msg_body %></textarea>
                </div>
                <button
                  type="submit"
                  class="w-full py-2.5 bg-gradient-to-r from-amber-600 to-amber-500 hover:from-amber-500 hover:to-amber-400 text-gray-950 font-bold rounded-lg text-xs transition-smooth uppercase tracking-wider"
                  style="box-shadow: 0 2px 10px rgba(245,158,11,0.2);"
                >
                  ⚡ Send Message
                </button>
                <%= if @msg_status do %>
                  <div
                    class={"text-xs text-center py-2 px-3 rounded-lg cursor-pointer fade-in " <> msg_toast_style(@msg_status)}
                    phx-click="clear_msg_status"
                  >
                    <%= msg_status_text(@msg_status) %>
                  </div>
                <% end %>
              </form>
            </div>

            <%!-- System Metrics --%>
            <div class="p-4 overflow-y-auto">
              <h2 class="text-[10px] font-semibold text-rf-text-muted uppercase tracking-[0.15em] mb-3">System Metrics</h2>
              <div class="space-y-3.5">
                <%= for {resource, label, icon} <- quota_resources() do %>
                  <% info = Map.get(@usage, resource, %{used: 0, limit: 0}) %>
                  <% pct = quota_percentage(info) %>
                  <div>
                    <div class="flex items-center justify-between text-xs mb-1.5">
                      <span class="text-rf-text-sec flex items-center gap-1.5">
                        <span><%= icon %></span>
                        <span class="text-[10px] uppercase tracking-wider"><%= label %></span>
                      </span>
                      <span class="text-rf-text-muted font-mono text-[11px]">
                        <span class="text-rf-text-sec"><%= format_quota_number(info[:used] || Map.get(info, :used, 0)) %></span>
                        <span class="text-rf-text-muted">/</span>
                        <span><%= format_quota_limit(info[:limit] || Map.get(info, :limit, 0)) %></span>
                      </span>
                    </div>
                    <div class="h-2 bg-rf-border/50 rounded-full overflow-hidden">
                      <div
                        class={"h-full rounded-full transition-all duration-700 ease-out " <> quota_bar_style(pct)}
                        style={"width: #{max(pct, 2)}%"}
                      ></div>
                    </div>
                  </div>
                <% end %>
              </div>
            </div>
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

  defp state_dot_color("online"), do: "#22c55e"
  defp state_dot_color("busy"), do: "#eab308"
  defp state_dot_color("away"), do: "#94a3b8"
  defp state_dot_color("offline"), do: "#ef4444"
  defp state_dot_color(_), do: "#475569"

  defp state_badge("online"), do: "bg-green-500/15 text-green-400 border border-green-500/20"
  defp state_badge("busy"), do: "bg-yellow-500/15 text-yellow-400 border border-yellow-500/20"
  defp state_badge("away"), do: "bg-gray-500/15 text-gray-400 border border-gray-500/20"
  defp state_badge("offline"), do: "bg-red-500/15 text-red-400 border border-red-500/20"
  defp state_badge(_), do: "bg-gray-500/15 text-gray-400 border border-gray-500/20"

  defp kind_badge_style("task_completed"), do: "bg-green-500/15 text-green-400"
  defp kind_badge_style("task_started"), do: "bg-blue-500/15 text-blue-400"
  defp kind_badge_style("task_progress"), do: "bg-cyan-500/15 text-cyan-400"
  defp kind_badge_style("task_failed"), do: "bg-red-500/15 text-red-400"
  defp kind_badge_style("discovery"), do: "bg-purple-500/15 text-purple-400"
  defp kind_badge_style("question"), do: "bg-yellow-500/15 text-yellow-400"
  defp kind_badge_style("alert"), do: "bg-red-500/15 text-red-400"
  defp kind_badge_style("join"), do: "bg-green-500/15 text-green-400"
  defp kind_badge_style("leave"), do: "bg-gray-500/15 text-gray-400"
  defp kind_badge_style(_), do: "bg-rf-border text-rf-text-sec"

  defp msg_toast_style({:ok, _}), do: "bg-green-500/10 text-green-400 border border-green-500/20"
  defp msg_toast_style({:error, _}), do: "bg-red-500/10 text-red-400 border border-red-500/20"

  defp quota_bar_style(pct) when pct >= 95, do: "bg-gradient-to-r from-red-500 to-red-400 bar-glow-red"
  defp quota_bar_style(pct) when pct >= 80, do: "bg-gradient-to-r from-yellow-500 to-yellow-400 bar-glow-yellow"
  defp quota_bar_style(_), do: "bg-gradient-to-r from-green-500 to-emerald-400 bar-glow-green"

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

  defp format_quota_number(n) when is_integer(n) and n >= 1000 do
    "#{Float.round(n / 1000, 1)}K"
  end
  defp format_quota_number(n), do: "#{n}"

  defp format_quota_limit(:unlimited), do: "∞"
  defp format_quota_limit(n) when is_integer(n) and n >= 1000 do
    "#{Float.round(n / 1000, 1)}K"
  end
  defp format_quota_limit(n), do: "#{n}"

  defp msg_status_text({:ok, status}), do: "✓ Message #{status}"
  defp msg_status_text({:error, reason}), do: "✗ #{reason}"
end
