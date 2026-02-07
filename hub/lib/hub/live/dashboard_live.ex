defmodule Hub.Live.DashboardLive do
  @moduledoc """
  Production-grade operator dashboard for Ringforge fleets.

  Multi-view LiveView with sidebar navigation:
  - Dashboard (overview with stats, agent grid, activity feed, quotas)
  - Agents (sortable table with slide-in detail panel)
  - Activity (full filterable stream with time grouping)
  - Messaging (conversation-style DM view)
  - Quotas & Metrics (large visual bars, plan info)
  - Settings (fleet configuration)

  Uses SaladUI (shadcn for LiveView) components.
  All updates PubSub-driven.
  """
  use Phoenix.LiveView
  use SaladUI

  alias Hub.FleetPresence
  alias Hub.Live.Components
  alias Hub.Live.Icons

  @activity_limit 100

  # ══════════════════════════════════════════════════════════
  # Mount
  # ══════════════════════════════════════════════════════════

  @impl true
  def mount(params, session, socket) do
    case authenticate(params, session) do
      {:ok, tenant_id, fleet_id, fleet_name, plan, tenant_email} ->
        socket = assign(socket,
          tenant_id: tenant_id,
          fleet_id: fleet_id,
          fleet_name: fleet_name,
          plan: plan,
          tenant_email: tenant_email,
          agents: %{},
          activities: [],
          usage: %{},
          current_view: "dashboard",
          sidebar_collapsed: false,
          selected_agent: nil,
          agent_detail_open: false,
          agent_activities: [],
          msg_to: nil,
          msg_body: "",
          messages: [],
          filter: "all",
          search_query: "",
          sort_by: :name,
          sort_dir: :asc,
          toast: nil,
          cmd_open: false,
          cmd_query: "",
          new_api_key: nil,
          new_api_key_type: nil,
          editing_fleet_name: false,
          show_all_agents: false,
          registered_agents: [],
          authenticated: true
        )

        if connected?(socket) do
          Hub.Events.subscribe()
          Phoenix.PubSub.subscribe(Hub.PubSub, "fleet:#{fleet_id}")
          Process.send_after(self(), :refresh_quota, 1_000)
          Process.send_after(self(), :clear_toast, 4_000)
        end

        agents = load_agents(fleet_id)
        activities = load_recent_activities(fleet_id)
        usage = load_usage(tenant_id)
        registered = load_registered_agents(tenant_id)

        {:ok, assign(socket, agents: agents, activities: activities, usage: usage, registered_agents: registered)}

      {:error, :unauthenticated} ->
        # Read error/tab from URL params (set by SessionController redirect)
        auth_error = params["error"]
        auth_tab = params["tab"] || "login"
        {:ok, assign(socket,
          authenticated: false,
          auth_error: auth_error,
          auth_tab: auth_tab,
          key_input: "",
          register_name: "",
          register_email: "",
          login_email: ""
        )}
    end
  end

  # ══════════════════════════════════════════════════════════
  # Events
  # ══════════════════════════════════════════════════════════

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("authenticate", %{"key" => key}, socket) do
    case validate_admin_key(key) do
      {:ok, tenant_id, fleet_id, fleet_name, plan, tenant_email} ->
        registered = load_registered_agents(tenant_id)
        socket = assign(socket,
          tenant_id: tenant_id, fleet_id: fleet_id, fleet_name: fleet_name, plan: plan,
          tenant_email: tenant_email,
          agents: load_agents(fleet_id),
          activities: load_recent_activities(fleet_id),
          usage: load_usage(tenant_id),
          registered_agents: registered,
          current_view: "dashboard", sidebar_collapsed: false,
          selected_agent: nil, agent_detail_open: false, agent_activities: [],
          msg_to: nil, msg_body: "", messages: [],
          filter: "all", search_query: "", sort_by: :name, sort_dir: :asc,
          toast: nil, cmd_open: false, cmd_query: "",
          new_api_key: nil, new_api_key_type: nil, editing_fleet_name: false,
          show_all_agents: false,
          authenticated: true, auth_error: nil
        )

        if connected?(socket) do
          Hub.Events.subscribe()
          Phoenix.PubSub.subscribe(Hub.PubSub, "fleet:#{fleet_id}")
          Process.send_after(self(), :refresh_quota, 1_000)
        end

        {:noreply, push_event(socket, "store_session", %{tenant_id: tenant_id})}

      {:error, _} ->
        {:noreply, assign(socket, auth_error: "Invalid admin API key")}
    end
  end

  # Auth tab switching
  def handle_event("switch_auth_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, auth_tab: tab, auth_error: nil)}
  end

  # Claim account — set email/password on existing tenant
  def handle_event("claim_account", %{"email" => email, "password" => password}, socket) do
    tenant = Hub.Repo.get(Hub.Auth.Tenant, socket.assigns.tenant_id)

    case Hub.Auth.Tenant.registration_changeset(tenant, %{name: tenant.name, email: email, password: password})
         |> Hub.Repo.update() do
      {:ok, updated} ->
        {:noreply, assign(socket,
          tenant_email: updated.email,
          toast: {:success, "Account claimed — you can now sign in with #{email}"}
        )}

      {:error, changeset} ->
        error = Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
                |> Enum.map_join(". ", fn {field, msgs} -> "#{field}: #{Enum.join(msgs, ", ")}" end)
        {:noreply, assign(socket, toast: {:error, error})}
    end
  end

  # Navigation
  def handle_event("navigate", %{"view" => view} = params, socket) do
    socket = assign(socket, current_view: view, cmd_open: false, cmd_query: "")

    socket = if view == "agents" && params["agent"] do
      assign(socket,
        selected_agent: params["agent"],
        agent_detail_open: true,
        agent_activities: filter_agent_activities(socket.assigns.activities, params["agent"])
      )
    else
      socket
    end

    socket = if view == "messaging" && params["agent"] do
      messages = load_conversation(socket.assigns.fleet_id, params["agent"])
      assign(socket, msg_to: params["agent"], messages: messages)
    else
      socket
    end

    {:noreply, socket}
  end

  def handle_event("toggle_sidebar", _, socket) do
    {:noreply, assign(socket, sidebar_collapsed: !socket.assigns.sidebar_collapsed)}
  end

  # Command palette
  def handle_event("toggle_command_palette", _, socket) do
    {:noreply, assign(socket, cmd_open: !socket.assigns.cmd_open, cmd_query: "")}
  end

  def handle_event("cmd_search", %{"value" => v}, socket) do
    {:noreply, assign(socket, cmd_query: v)}
  end

  def handle_event("cmd_navigate", %{"view" => view}, socket) do
    {:noreply, assign(socket, current_view: view, cmd_open: false, cmd_query: "")}
  end

  def handle_event("cmd_go_agent", %{"agent" => agent_id}, socket) do
    {:noreply, assign(socket,
      current_view: "agents",
      selected_agent: agent_id,
      agent_detail_open: true,
      agent_activities: filter_agent_activities(socket.assigns.activities, agent_id),
      cmd_open: false, cmd_query: ""
    )}
  end

  # Agent detail
  def handle_event("select_agent_detail", %{"agent-id" => agent_id}, socket) do
    {:noreply, assign(socket,
      selected_agent: agent_id,
      agent_detail_open: true,
      agent_activities: filter_agent_activities(socket.assigns.activities, agent_id)
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

  def handle_event("update_msg_body", %{"value" => v}, socket) do
    {:noreply, assign(socket, msg_body: v)}
  end

  def handle_event("send_message", %{"body" => body}, socket) do
    to = socket.assigns.msg_to
    if to && String.trim(body) != "" do
      case Hub.DirectMessage.send_message(socket.assigns.fleet_id, "dashboard", to, %{"text" => body}) do
        {:ok, result} ->
          messages = load_conversation(socket.assigns.fleet_id, to)
          Process.send_after(self(), :clear_toast, 4_000)
          {:noreply, assign(socket, msg_body: "", messages: messages, toast: {:success, "Message #{result.status}"})}
        {:error, reason} ->
          Process.send_after(self(), :clear_toast, 4_000)
          {:noreply, assign(socket, toast: {:error, "Failed: #{reason}"})}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("send_dm_from_detail", _, socket) do
    agent_id = socket.assigns.selected_agent
    messages = load_conversation(socket.assigns.fleet_id, agent_id)
    {:noreply, assign(socket, current_view: "messaging", msg_to: agent_id, messages: messages, agent_detail_open: false, selected_agent: nil)}
  end

  # Filter / Search / Sort
  def handle_event("set_filter", %{"filter" => f}, socket), do: {:noreply, assign(socket, filter: f)}
  def handle_event("update_search", %{"value" => v}, socket), do: {:noreply, assign(socket, search_query: v)}
  def handle_event("sort_agents", %{"column" => col}, socket) do
    col = String.to_existing_atom(col)
    dir = if socket.assigns.sort_by == col && socket.assigns.sort_dir == :asc, do: :desc, else: :asc
    {:noreply, assign(socket, sort_by: col, sort_dir: dir)}
  end

  def handle_event("clear_toast", _, socket), do: {:noreply, assign(socket, toast: nil)}

  # ── ESC key handler ────────────────────────────────────────

  def handle_event("esc_pressed", _, socket) do
    cond do
      socket.assigns.cmd_open ->
        {:noreply, assign(socket, cmd_open: false, cmd_query: "")}
      socket.assigns.agent_detail_open ->
        {:noreply, assign(socket, agent_detail_open: false)}
      true ->
        {:noreply, socket}
    end
  end

  # ── Logout ─────────────────────────────────────────────────

  def handle_event("logout", _, socket) do
    {:noreply, redirect(socket, to: "/auth/logout")}
  end

  # ── Activity: click to open agent ──────────────────────────

  def handle_event("activity_click_agent", %{"agent-id" => agent_id}, socket) do
    {:noreply, assign(socket,
      current_view: "agents",
      selected_agent: agent_id,
      agent_detail_open: true,
      agent_activities: filter_agent_activities(socket.assigns.activities, agent_id)
    )}
  end

  # ── Agents: toggle connected/all ───────────────────────────

  def handle_event("toggle_agent_view", _, socket) do
    new_val = !socket.assigns.show_all_agents
    socket = if new_val do
      assign(socket, show_all_agents: true, registered_agents: load_registered_agents(socket.assigns.tenant_id))
    else
      assign(socket, show_all_agents: false)
    end
    {:noreply, socket}
  end

  # ── Agents: deregister (delete from DB) ────────────────────

  def handle_event("deregister_agent", %{"agent-id" => agent_id}, socket) do
    import Ecto.Query
    agent = Hub.Repo.get_by(Hub.Auth.Agent, agent_id: agent_id)
    case agent do
      nil ->
        Process.send_after(self(), :clear_toast, 4_000)
        {:noreply, assign(socket, toast: {:error, "Agent not found"})}
      a ->
        case Hub.Repo.delete(a) do
          {:ok, _} ->
            # Also kick if online
            Hub.Endpoint.broadcast("agent:#{agent_id}", "disconnect", %{reason: "deregistered"})
            registered = load_registered_agents(socket.assigns.tenant_id)
            Process.send_after(self(), :clear_toast, 4_000)
            {:noreply, assign(socket,
              registered_agents: registered,
              agents: Map.delete(socket.assigns.agents, agent_id),
              agent_detail_open: false, selected_agent: nil,
              toast: {:success, "Agent #{agent_id} deregistered"}
            )}
          {:error, _} ->
            Process.send_after(self(), :clear_toast, 4_000)
            {:noreply, assign(socket, toast: {:error, "Failed to deregister agent"})}
        end
    end
  end

  # ── Settings: Fleet name editing ──────────────────────────────

  def handle_event("edit_fleet_name", _, socket) do
    {:noreply, assign(socket, editing_fleet_name: true)}
  end

  def handle_event("cancel_edit_fleet_name", _, socket) do
    {:noreply, assign(socket, editing_fleet_name: false)}
  end

  def handle_event("rename_fleet", %{"name" => name}, socket) do
    name = String.trim(name)
    if name == "" do
      Process.send_after(self(), :clear_toast, 4_000)
      {:noreply, assign(socket, toast: {:error, "Fleet name cannot be empty"})}
    else
      import Ecto.Query
      case Hub.Repo.get(Hub.Auth.Fleet, socket.assigns.fleet_id) do
        nil ->
          Process.send_after(self(), :clear_toast, 4_000)
          {:noreply, assign(socket, toast: {:error, "Fleet not found"})}
        fleet ->
          case fleet |> Hub.Auth.Fleet.changeset(%{name: name}) |> Hub.Repo.update() do
            {:ok, updated} ->
              Process.send_after(self(), :clear_toast, 4_000)
              {:noreply, assign(socket, fleet_name: updated.name, editing_fleet_name: false, toast: {:success, "Fleet renamed to \"#{updated.name}\""})}
            {:error, _} ->
              Process.send_after(self(), :clear_toast, 4_000)
              {:noreply, assign(socket, toast: {:error, "Failed to rename fleet"})}
          end
      end
    end
  end

  # ── Settings: API key rotation ─────────────────────────────

  def handle_event("rotate_api_key", %{"type" => type}, socket) when type in ["live", "test", "admin"] do
    tenant_id = socket.assigns.tenant_id
    fleet_id = socket.assigns.fleet_id

    # Revoke all existing keys of this type for the tenant
    import Ecto.Query
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    from(k in Hub.Auth.ApiKey,
      where: k.tenant_id == ^tenant_id and k.type == ^type and is_nil(k.revoked_at)
    ) |> Hub.Repo.update_all(set: [revoked_at: now])

    # Generate new key
    case Hub.Auth.generate_api_key(type, tenant_id, fleet_id) do
      {:ok, raw_key, _api_key} ->
        Process.send_after(self(), :clear_toast, 8_000)
        {:noreply, assign(socket,
          toast: {:success, "New #{type} key: #{raw_key}"},
          new_api_key: raw_key,
          new_api_key_type: type
        )}
      {:error, _} ->
        Process.send_after(self(), :clear_toast, 4_000)
        {:noreply, assign(socket, toast: {:error, "Failed to generate key"})}
    end
  end

  def handle_event("rotate_api_key", _, socket) do
    Process.send_after(self(), :clear_toast, 4_000)
    {:noreply, assign(socket, toast: {:error, "Invalid key type"})}
  end

  def handle_event("dismiss_new_key", _, socket) do
    {:noreply, assign(socket, new_api_key: nil, new_api_key_type: nil)}
  end

  # ── Agent: Kick / Disconnect ───────────────────────────────

  def handle_event("kick_agent", %{"agent-id" => agent_id}, socket) do
    # Force-disconnect via Endpoint broadcast to the agent's socket
    Hub.Endpoint.broadcast("agent:#{agent_id}", "disconnect", %{reason: "kicked_by_admin"})

    Process.send_after(self(), :clear_toast, 4_000)
    {:noreply, assign(socket,
      toast: {:success, "Kicked agent: #{agent_id}"},
      agent_detail_open: false,
      selected_agent: nil
    )}
  end

  # ══════════════════════════════════════════════════════════
  # PubSub Handlers
  # ══════════════════════════════════════════════════════════

  @impl true
  def handle_info({:hub_event, event}, socket) do
    {:noreply, handle_hub_event(event, socket)}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff", payload: diff}, socket) do
    agents = socket.assigns.agents
    agents = Enum.reduce(Map.get(diff, :joins, %{}), agents, fn {id, %{metas: [m | _]}}, acc ->
      Map.put(acc, id, normalize_meta(m))
    end)
    agents = Enum.reduce(Map.get(diff, :leaves, %{}), agents, fn {id, _}, acc ->
      Map.delete(acc, id)
    end)
    {:noreply, assign(socket, agents: agents)}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence:joined", payload: payload}, socket) do
    p = payload["payload"] || payload
    agent_id = p["agent_id"]
    if agent_id do
      meta = %{
        name: p["name"] || agent_id, state: p["state"] || "online",
        capabilities: p["capabilities"] || [], task: p["task"],
        framework: p["framework"], connected_at: p["connected_at"]
      }
      activity = %{
        kind: "join", agent_id: agent_id, agent_name: meta.name,
        description: "connected to fleet",
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
      }
      {:noreply, assign(socket,
        agents: Map.put(socket.assigns.agents, agent_id, meta),
        activities: prepend_activity(socket.assigns.activities, activity)
      )}
    else
      {:noreply, socket}
    end
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence:left", payload: payload}, socket) do
    p = payload["payload"] || payload
    agent_id = p["agent_id"]
    if agent_id do
      name = case Map.get(socket.assigns.agents, agent_id) do
        %{name: n} -> n
        _ -> agent_id
      end
      activity = %{
        kind: "leave", agent_id: agent_id, agent_name: name,
        description: "disconnected from fleet",
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
      }
      {:noreply, assign(socket,
        agents: Map.delete(socket.assigns.agents, agent_id),
        activities: prepend_activity(socket.assigns.activities, activity)
      )}
    else
      {:noreply, socket}
    end
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence:state_changed", payload: payload}, socket) do
    p = payload["payload"] || payload
    agent_id = p["agent_id"]
    if agent_id do
      agents = Map.update(socket.assigns.agents, agent_id, %{}, fn ex ->
        ex |> Map.put(:state, p["state"] || ex[:state])
           |> Map.put(:task, p["task"] || ex[:task])
           |> Map.put(:name, p["name"] || ex[:name])
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
    {:noreply, assign(socket, activities: prepend_activity(socket.assigns.activities, activity))}
  end

  def handle_info({:quota_warning, _msg}, socket) do
    Process.send_after(self(), :clear_toast, 4_000)
    {:noreply, assign(socket,
      usage: load_usage(socket.assigns.tenant_id),
      toast: {:warning, "Quota warning — check usage"}
    )}
  end

  def handle_info(:refresh_quota, socket) do
    if socket.assigns[:authenticated] do
      Process.send_after(self(), :refresh_quota, 5_000)
      {:noreply, assign(socket, usage: load_usage(socket.assigns.tenant_id))}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:clear_toast, socket), do: {:noreply, assign(socket, toast: nil)}

  def handle_info(%Phoenix.Socket.Broadcast{}, socket), do: {:noreply, socket}
  def handle_info(_msg, socket), do: {:noreply, socket}

  # ══════════════════════════════════════════════════════════
  # Render
  # ══════════════════════════════════════════════════════════

  @impl true
  def render(assigns) do
    if assigns[:authenticated], do: render_app(assigns), else: render_login(assigns)
  end

  # ── Login ─────────────────────────────────────────────────

  defp render_login(assigns) do
    ~H"""
    <div class="min-h-screen flex items-center justify-center bg-zinc-950 bg-grid bg-radial-glow p-4">
      <div class="w-full max-w-md animate-fade-in-up">
        <%!-- Logo & branding --%>
        <div class="text-center mb-8">
          <div class="inline-flex items-center justify-center w-14 h-14 rounded-2xl bg-amber-500/15 border border-amber-500/25 mb-4">
            <Icons.zap class="w-7 h-7 text-amber-400" />
          </div>
          <h1 class="text-2xl font-bold tracking-tight">
            <span class="text-zinc-100">Ring</span><span class="text-amber-400">Forge</span>
          </h1>
          <p class="text-sm text-zinc-500 mt-1">Agent Coordination Mesh</p>
        </div>

        <.card class="bg-zinc-900/95 backdrop-blur-sm border-zinc-800 shadow-2xl">
          <.card_content class="pt-6">
            <%!-- Tab bar --%>
            <div class="flex border-b border-zinc-800 mb-6 -mx-1">
              <button
                phx-click="switch_auth_tab" phx-value-tab="login"
                class={"flex-1 pb-3 text-sm font-medium border-b-2 transition-colors mx-1 " <>
                  if(@auth_tab == "login",
                    do: "border-amber-400 text-amber-400",
                    else: "border-transparent text-zinc-500 hover:text-zinc-300")}
              >
                Sign In
              </button>
              <button
                phx-click="switch_auth_tab" phx-value-tab="register"
                class={"flex-1 pb-3 text-sm font-medium border-b-2 transition-colors mx-1 " <>
                  if(@auth_tab == "register",
                    do: "border-amber-400 text-amber-400",
                    else: "border-transparent text-zinc-500 hover:text-zinc-300")}
              >
                Register
              </button>
              <button
                phx-click="switch_auth_tab" phx-value-tab="apikey"
                class={"flex-1 pb-3 text-sm font-medium border-b-2 transition-colors mx-1 " <>
                  if(@auth_tab == "apikey",
                    do: "border-amber-400 text-amber-400",
                    else: "border-transparent text-zinc-500 hover:text-zinc-300")}
              >
                API Key
              </button>
            </div>

            <%!-- Error message --%>
            <%= if @auth_error do %>
              <div class="flex items-center gap-2 text-sm text-red-400 bg-red-500/10 border border-red-500/20 rounded-lg py-2.5 px-3 mb-4 animate-fade-in">
                <Icons.alert_triangle class="w-4 h-4 flex-shrink-0" />
                <span><%= @auth_error %></span>
              </div>
            <% end %>

            <%!-- Login tab --%>
            <%= if @auth_tab == "login" do %>
              <form action="/auth/login" method="post" class="space-y-4 animate-fade-in">
                <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
                <div>
                  <label class="text-xs text-zinc-400 mb-1.5 block font-medium">Email</label>
                  <.input
                    type="email"
                    name="email"
                    value={@login_email}
                    placeholder="you@example.com"
                    autocomplete="email"
                    required
                    class="w-full bg-zinc-950 border-zinc-700 text-zinc-100 placeholder:text-zinc-600 focus:border-amber-500/50"
                  />
                </div>
                <div>
                  <label class="text-xs text-zinc-400 mb-1.5 block font-medium">Password</label>
                  <.input
                    type="password"
                    name="password"
                    placeholder="••••••••"
                    autocomplete="current-password"
                    required
                    class="w-full bg-zinc-950 border-zinc-700 text-zinc-100 placeholder:text-zinc-600 focus:border-amber-500/50"
                  />
                </div>
                <.button
                  type="submit"
                  class="w-full bg-amber-500 hover:bg-amber-400 text-zinc-950 font-semibold h-10"
                >
                  <Icons.log_in class="w-4 h-4 mr-2" />
                  Sign In
                </.button>
              </form>
            <% end %>

            <%!-- Register tab --%>
            <%= if @auth_tab == "register" do %>
              <form action="/auth/register" method="post" class="space-y-4 animate-fade-in">
                <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
                <div>
                  <label class="text-xs text-zinc-400 mb-1.5 block font-medium">Organization Name</label>
                  <.input
                    type="text"
                    name="name"
                    value={@register_name}
                    placeholder="My Company"
                    autocomplete="organization"
                    required
                    class="w-full bg-zinc-950 border-zinc-700 text-zinc-100 placeholder:text-zinc-600 focus:border-amber-500/50"
                  />
                </div>
                <div>
                  <label class="text-xs text-zinc-400 mb-1.5 block font-medium">Email</label>
                  <.input
                    type="email"
                    name="email"
                    value={@register_email}
                    placeholder="you@example.com"
                    autocomplete="email"
                    required
                    class="w-full bg-zinc-950 border-zinc-700 text-zinc-100 placeholder:text-zinc-600 focus:border-amber-500/50"
                  />
                </div>
                <div>
                  <label class="text-xs text-zinc-400 mb-1.5 block font-medium">Password</label>
                  <.input
                    type="password"
                    name="password"
                    placeholder="Min. 8 characters"
                    autocomplete="new-password"
                    required
                    minlength="8"
                    class="w-full bg-zinc-950 border-zinc-700 text-zinc-100 placeholder:text-zinc-600 focus:border-amber-500/50"
                  />
                </div>
                <.button
                  type="submit"
                  class="w-full bg-amber-500 hover:bg-amber-400 text-zinc-950 font-semibold h-10"
                >
                  <Icons.user_plus class="w-4 h-4 mr-2" />
                  Create Account
                </.button>
                <p class="text-xs text-zinc-600 text-center">
                  Free plan · 5 agents · No credit card required
                </p>
              </form>
            <% end %>

            <%!-- API Key tab --%>
            <%= if @auth_tab == "apikey" do %>
              <form phx-submit="authenticate" class="space-y-4 animate-fade-in">
                <div>
                  <label class="text-xs text-zinc-400 mb-1.5 block font-medium">Admin API Key</label>
                  <.input
                    type="password"
                    name="key"
                    value={@key_input}
                    placeholder="rf_admin_..."
                    autocomplete="off"
                    class="w-full bg-zinc-950 border-zinc-700 text-zinc-100 placeholder:text-zinc-600 focus:border-amber-500/50"
                  />
                </div>
                <.button
                  type="submit"
                  class="w-full bg-zinc-800 hover:bg-zinc-700 text-zinc-100 font-semibold h-10 border border-zinc-700"
                >
                  <Icons.key class="w-4 h-4 mr-2" />
                  Authenticate
                </.button>
                <p class="text-xs text-zinc-600 text-center">
                  Use your admin key for direct access
                </p>
              </form>
            <% end %>
          </.card_content>
        </.card>

        <p class="text-xs text-zinc-600 text-center mt-6">
          RingForge v0.1 · Multi-tenant agent mesh
        </p>
      </div>
    </div>
    """
  end

  # ── App Shell ─────────────────────────────────────────────

  defp render_app(assigns) do
    online = Enum.count(assigns.agents, fn {_, m} -> m[:state] == "online" end)
    msg_used = get_in(assigns.usage, [:messages_today, :used]) || 0

    assigns = assign(assigns, online_count: online, msg_used: msg_used)

    ~H"""
    <div class="h-screen w-screen flex flex-col overflow-hidden bg-zinc-950" id="app" phx-hook="EscListener">
      <%!-- Toast --%>
      <%= if @toast do %>
        <Components.toast type={elem(@toast, 0)} message={elem(@toast, 1)} />
      <% end %>

      <%!-- Command Palette --%>
      <Components.command_palette open={@cmd_open} query={@cmd_query} agents={@agents} />

      <%!-- Header --%>
      <header class="h-12 border-b border-zinc-800 flex items-center justify-between px-4 shrink-0 bg-zinc-950">
        <div class="flex items-center gap-3">
          <.button variant="ghost" size="icon" phx-click="toggle_sidebar" class="h-8 w-8 text-zinc-400 hover:text-zinc-200">
            <Icons.menu class="w-4 h-4" />
          </.button>
          <div class="flex items-center gap-2">
            <div class="w-7 h-7 rounded-lg bg-amber-500/15 border border-amber-500/25 flex items-center justify-center text-amber-400">
              <Icons.zap class="w-3.5 h-3.5" />
            </div>
            <span class="text-sm font-semibold text-zinc-200">Ring<span class="text-amber-400">Forge</span></span>
            <.separator orientation="vertical" class="h-4 mx-1" />
            <span class="text-xs text-zinc-500"><%= @fleet_name %></span>
          </div>
        </div>

        <div class="flex items-center gap-3">
          <%!-- Cmd+K button --%>
          <.button variant="outline" size="sm" phx-click="toggle_command_palette" class="hidden sm:flex items-center gap-2 border-zinc-800 hover:border-zinc-700 text-zinc-500 hover:text-zinc-300">
            <Icons.search class="w-3.5 h-3.5" />
            <span>Search</span>
            <kbd class="px-1 py-0.5 text-[10px] rounded bg-zinc-800 border border-zinc-700 text-zinc-500">⌘K</kbd>
          </.button>
          <%!-- Quick stats --%>
          <div class="hidden md:flex items-center gap-3 text-xs text-zinc-400">
            <div class="flex items-center gap-1.5">
              <span class="w-1.5 h-1.5 rounded-full bg-green-400 animate-pulse-dot"></span>
              <span><%= @online_count %> online</span>
            </div>
            <.separator orientation="vertical" class="h-3" />
            <span><%= Components.fmt_num(@msg_used) %> msgs</span>
          </div>
          <%!-- Live indicator --%>
          <.badge variant="outline" class="border-green-500/20 bg-green-500/5 text-green-400 text-[10px] font-medium">
            <span class="w-1.5 h-1.5 rounded-full bg-green-400 animate-pulse-dot mr-1.5"></span>
            Live
          </.badge>
          <%!-- Logout --%>
          <.button variant="ghost" size="icon" phx-click="logout" title="Sign out" class="h-8 w-8 text-zinc-500 hover:text-red-400">
            <Icons.log_out class="w-4 h-4" />
          </.button>
        </div>
      </header>

      <%!-- Main: sidebar + content --%>
      <div class="flex-1 flex overflow-hidden">
        <%!-- Sidebar --%>
        <aside class={"border-r border-zinc-800 shrink-0 overflow-y-auto transition-all duration-200 bg-zinc-900 " <> if(@sidebar_collapsed, do: "w-0 overflow-hidden border-r-0", else: "w-56")}>
          <nav class="p-3 space-y-0.5">
            <div class="px-3 py-2 mb-1">
              <span class="text-[10px] font-semibold text-zinc-500 uppercase tracking-wider">Menu</span>
            </div>
            <Components.nav_item view="dashboard" icon={:layout_dashboard} label="Dashboard" active={@current_view == "dashboard"} />
            <Components.nav_item view="agents" icon={:bot} label="Agents" active={@current_view == "agents"} badge={to_string(map_size(@agents))} />
            <Components.nav_item view="activity" icon={:activity} label="Activity" active={@current_view == "activity"} />
            <Components.nav_item view="messaging" icon={:message_square} label="Messaging" active={@current_view == "messaging"} />
            <Components.nav_item view="quotas" icon={:gauge} label="Quotas" active={@current_view == "quotas"} />
            <Components.nav_item view="settings" icon={:settings} label="Settings" active={@current_view == "settings"} />

            <.separator class="my-4" />

            <.card class="bg-zinc-800/50 border-zinc-700/50">
              <.card_content class="p-3">
                <div class="text-[10px] text-zinc-500 mb-0.5">Plan</div>
                <div class="text-xs font-medium text-amber-400 capitalize"><%= @plan %></div>
                <div class="text-[10px] text-zinc-600 mt-1"><%= map_size(@agents) %> agents</div>
              </.card_content>
            </.card>
          </nav>
        </aside>

        <%!-- Content --%>
        <main class="flex-1 min-w-0 overflow-hidden bg-zinc-950">
          <%= case @current_view do %>
            <% "dashboard" -> %> <%= render_overview(assigns) %>
            <% "agents" -> %> <%= render_agents(assigns) %>
            <% "activity" -> %> <%= render_activity(assigns) %>
            <% "messaging" -> %> <%= render_messaging(assigns) %>
            <% "quotas" -> %> <%= render_quotas(assigns) %>
            <% "settings" -> %> <%= render_settings(assigns) %>
            <% _ -> %> <%= render_overview(assigns) %>
          <% end %>
        </main>
      </div>
    </div>
    """
  end

  # ══════════════════════════════════════════════════════════
  # Page: Dashboard Overview
  # ══════════════════════════════════════════════════════════

  defp render_overview(assigns) do
    agents_sorted = assigns.agents
      |> Enum.sort_by(fn {_id, m} -> Components.state_sort_order(m[:state]) end)
      |> Enum.take(12)

    recent = Enum.take(assigns.activities, 8)
    online = Enum.count(assigns.agents, fn {_, m} -> m[:state] == "online" end)
    msg_info = Map.get(assigns.usage, :messages_today, %{used: 0, limit: 0})
    mem_info = Map.get(assigns.usage, :memory_entries, %{used: 0, limit: 0})

    assigns = assign(assigns,
      agents_sorted: agents_sorted, recent: recent,
      ov_online: online, msg_info: msg_info, mem_info: mem_info
    )

    ~H"""
    <div class="h-full overflow-y-auto p-6 space-y-6 animate-fade-in">
      <div>
        <h2 class="text-lg font-semibold text-zinc-100">Dashboard</h2>
        <p class="text-sm text-zinc-500">Fleet overview and real-time status</p>
      </div>

      <%!-- Stat cards --%>
      <div class="grid grid-cols-2 lg:grid-cols-4 gap-3 lg-grid-4">
        <Components.stat_card label="Total Agents" value={to_string(map_size(@agents))} icon={:bot} color="amber" />
        <Components.stat_card label="Online Now" value={to_string(@ov_online)} icon={:wifi} color="green" delta={"+" <> to_string(@ov_online)} delta_type={:positive} />
        <Components.stat_card label="Messages Today" value={Components.fmt_num(@msg_info[:used] || 0)} icon={:message_square} color="blue" />
        <Components.stat_card label="Memory Used" value={to_string(Components.quota_pct(@mem_info)) <> "%"} icon={:brain} color="purple" />
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-[1fr_360px] gap-6 lg-grid-sidebar">
        <%!-- Agent grid --%>
        <div>
          <div class="flex items-center justify-between mb-3">
            <h3 class="text-sm font-medium text-zinc-300">Active Agents</h3>
            <.button variant="link" phx-click="navigate" phx-value-view="agents" class="text-xs text-amber-400 hover:text-amber-300 p-0 h-auto">View all →</.button>
          </div>
          <%= if map_size(@agents) == 0 do %>
            <Components.empty_state message="No agents connected" subtitle="Agents appear here when they join the fleet" icon={:bot} />
          <% else %>
            <div class="grid grid-cols-2 xl:grid-cols-3 gap-2">
              <%= for {agent_id, meta} <- @agents_sorted do %>
                <Components.agent_grid_card agent_id={agent_id} meta={meta} />
              <% end %>
            </div>
          <% end %>
        </div>

        <%!-- Right column --%>
        <div class="space-y-6">
          <%!-- Mini activity --%>
          <div>
            <div class="flex items-center justify-between mb-2">
              <div class="flex items-center gap-2">
                <h3 class="text-sm font-medium text-zinc-300">Recent Activity</h3>
                <span class="w-1.5 h-1.5 rounded-full bg-green-400 animate-pulse-dot"></span>
              </div>
              <.button variant="link" phx-click="navigate" phx-value-view="activity" class="text-xs text-amber-400 hover:text-amber-300 p-0 h-auto">View all →</.button>
            </div>
            <%= if @recent == [] do %>
              <.card class="bg-zinc-900 border-zinc-800">
                <.card_content class="p-4 text-center">
                  <p class="text-sm text-zinc-500">No activity yet</p>
                </.card_content>
              </.card>
            <% else %>
              <div class="space-y-0.5">
                <%= for a <- @recent do %>
                  <Components.activity_item activity={a} compact={true} />
                <% end %>
              </div>
            <% end %>
          </div>

          <%!-- Quota mini --%>
          <div>
            <div class="flex items-center justify-between mb-2">
              <h3 class="text-sm font-medium text-zinc-300">Quota Usage</h3>
              <.button variant="link" phx-click="navigate" phx-value-view="quotas" class="text-xs text-amber-400 hover:text-amber-300 p-0 h-auto">Details →</.button>
            </div>
            <.card class="bg-zinc-900 border-zinc-800">
              <.card_content class="p-4 space-y-3">
                <%= for {resource, label, icon, _color} <- Components.quota_resources() do %>
                  <% info = Map.get(@usage, resource, %{used: 0, limit: 0}) %>
                  <Components.quota_bar label={label} icon={icon} info={info} />
                <% end %>
              </.card_content>
            </.card>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ══════════════════════════════════════════════════════════
  # Page: Agents
  # ══════════════════════════════════════════════════════════

  defp render_agents(assigns) do
    # Merge connected (Presence) + registered (DB) if show_all
    all_agents = if assigns.show_all_agents do
      # Start with registered agents from DB
      registered_map = Map.new(assigns.registered_agents, fn a ->
        {a.agent_id, %{
          name: a.name || a.agent_id,
          state: "offline",
          capabilities: a.capabilities || [],
          task: nil,
          framework: a.framework,
          connected_at: nil,
          last_seen_at: a.last_seen_at,
          db_id: a.id
        }}
      end)
      # Overlay with live presence data (online agents)
      Map.merge(registered_map, assigns.agents)
    else
      assigns.agents
    end

    list = all_agents
      |> Enum.map(fn {id, m} -> {id, m} end)
      |> filter_agents(assigns.search_query)
      |> sort_agents(assigns.sort_by, assigns.sort_dir)

    online_count = Enum.count(assigns.agents, fn {_,m} -> m[:state] == "online" end)
    total_registered = length(assigns.registered_agents)

    assigns = assign(assigns, agents_list: list, agents_online: online_count, total_registered: total_registered)

    ~H"""
    <div class="h-full flex animate-fade-in">
      <div class="flex-1 flex flex-col overflow-hidden">
        <%!-- Header --%>
        <div class="px-6 py-4 border-b border-zinc-800 shrink-0">
          <div class="flex items-center justify-between">
            <div>
              <h2 class="text-lg font-semibold text-zinc-100">Agents</h2>
              <p class="text-sm text-zinc-500"><%= @total_registered %> registered · <%= @agents_online %> online</p>
            </div>
            <div class="flex items-center gap-3">
              <%!-- Connected/All toggle --%>
              <div class="flex rounded-lg border border-zinc-800 p-0.5 bg-zinc-900">
                <.button
                  variant={if(!@show_all_agents, do: "secondary", else: "ghost")}
                  size="sm"
                  phx-click={if @show_all_agents, do: "toggle_agent_view", else: nil}
                  class={"text-[10px] px-2.5 py-1 h-auto rounded-md font-medium " <> if(!@show_all_agents, do: "bg-zinc-800 text-zinc-100", else: "text-zinc-500 hover:text-zinc-300")}
                >
                  Connected
                </.button>
                <.button
                  variant={if(@show_all_agents, do: "secondary", else: "ghost")}
                  size="sm"
                  phx-click={if !@show_all_agents, do: "toggle_agent_view", else: nil}
                  class={"text-[10px] px-2.5 py-1 h-auto rounded-md font-medium " <> if(@show_all_agents, do: "bg-zinc-800 text-zinc-100", else: "text-zinc-500 hover:text-zinc-300")}
                >
                  All
                </.button>
              </div>
              <div class="relative">
                <.input
                  type="text" placeholder="Search agents..." value={@search_query} phx-keyup="update_search"
                  class="w-56 pl-8 bg-zinc-900 border-zinc-800 text-zinc-100 placeholder:text-zinc-600 focus:border-zinc-600"
                />
                <span class="absolute left-2.5 top-3 text-zinc-500"><Icons.search class="w-3.5 h-3.5" /></span>
              </div>
            </div>
          </div>
        </div>

        <%!-- Table --%>
        <div class="flex-1 overflow-auto">
          <%= if @agents_list == [] do %>
            <Components.empty_state message="No agents found" subtitle="Try a different search or wait for agents" icon={:search} />
          <% else %>
            <.table>
              <.table_header class="sticky top-0 z-10 bg-zinc-900/95 backdrop-blur-sm">
                <.table_row class="border-zinc-800 hover:bg-transparent">
                  <%= for {col, label} <- [{:name, "Name"}, {:state, "State"}] do %>
                    <.table_head>
                      <button phx-click="sort_agents" phx-value-column={Atom.to_string(col)} class="text-[10px] font-semibold text-zinc-500 uppercase tracking-wider hover:text-zinc-300 transition-colors flex items-center gap-1">
                        <%= label %> <%= sort_arrow(@sort_by, @sort_dir, col) %>
                      </button>
                    </.table_head>
                  <% end %>
                  <.table_head><span class="text-[10px] font-semibold text-zinc-500 uppercase tracking-wider">Capabilities</span></.table_head>
                  <.table_head><span class="text-[10px] font-semibold text-zinc-500 uppercase tracking-wider">Task</span></.table_head>
                  <.table_head><span class="text-[10px] font-semibold text-zinc-500 uppercase tracking-wider">Connected</span></.table_head>
                  <.table_head>
                    <button phx-click="sort_agents" phx-value-column="framework" class="text-[10px] font-semibold text-zinc-500 uppercase tracking-wider hover:text-zinc-300 transition-colors flex items-center gap-1">
                      Framework <%= sort_arrow(@sort_by, @sort_dir, :framework) %>
                    </button>
                  </.table_head>
                </.table_row>
              </.table_header>
              <.table_body>
                <%= for {id, meta} <- @agents_list do %>
                  <Components.agent_table_row agent_id={id} meta={meta} selected={@selected_agent == id} />
                <% end %>
              </.table_body>
            </.table>
          <% end %>
        </div>
      </div>

      <%!-- Agent Detail Sheet --%>
      <.sheet class="contents">
        <.sheet_content id="agent-detail-sheet" side="right" class="bg-zinc-900 border-zinc-800 p-0">
          <%= if @selected_agent do %>
            <% dm = Map.get(@agents, @selected_agent, %{}) %>
            <div class="p-5 space-y-5">
              <.sheet_header>
                <.sheet_title class="text-sm font-medium text-zinc-200">Agent Detail</.sheet_title>
                <.sheet_description class="text-xs text-zinc-500">Inspect agent state and activity</.sheet_description>
              </.sheet_header>

              <.card class="bg-zinc-800/50 border-zinc-700/50">
                <.card_content class="p-4">
                  <div class="flex items-center gap-3 mb-3">
                    <div class={"w-10 h-10 rounded-xl flex items-center justify-center text-sm font-bold " <> Components.avatar_bg(dm[:state])}>
                      <%= Components.avatar_initial(dm[:name] || @selected_agent) %>
                    </div>
                    <div>
                      <div class="text-sm font-semibold text-zinc-100"><%= dm[:name] || @selected_agent %></div>
                      <div class="flex items-center gap-1.5">
                        <span class={"w-2 h-2 rounded-full " <> Components.state_dot(dm[:state])}></span>
                        <.badge variant="outline" class={"text-[10px] " <> Components.state_badge(dm[:state])}><%= dm[:state] || "unknown" %></.badge>
                      </div>
                    </div>
                  </div>

                  <.separator class="my-3" />

                  <div class="space-y-2 text-xs">
                    <%= for {label, val} <- [{"ID", @selected_agent}, {"Framework", dm[:framework] || "—"}, {"Connected", Components.format_connected_at(dm[:connected_at])}] do %>
                      <div class="flex justify-between py-1 border-b border-zinc-700/30">
                        <span class="text-zinc-500"><%= label %></span>
                        <span class="text-zinc-300 font-mono text-[11px] truncate ml-3 max-w-[160px]"><%= val %></span>
                      </div>
                    <% end %>
                    <div class="py-1">
                      <span class="text-zinc-500 block mb-1">Task</span>
                      <span class="text-zinc-300 text-[11px]"><%= dm[:task] || "No active task" %></span>
                    </div>
                  </div>
                </.card_content>
              </.card>

              <%!-- Capabilities --%>
              <div>
                <div class="text-[10px] font-semibold text-zinc-500 uppercase tracking-wider mb-2">Capabilities</div>
                <%= if dm[:capabilities] && dm[:capabilities] != [] do %>
                  <div class="flex flex-wrap gap-1.5">
                    <%= for cap <- List.wrap(dm[:capabilities]) do %>
                      <.badge variant="outline" class="text-[10px] px-2 py-0.5 bg-amber-500/10 text-amber-400 border-amber-500/15"><%= cap %></.badge>
                    <% end %>
                  </div>
                <% else %>
                  <p class="text-xs text-zinc-600 italic">None registered</p>
                <% end %>
              </div>

              <div class="flex gap-2">
                <.button phx-click="send_dm_from_detail"
                  class="flex-1 bg-amber-500 hover:bg-amber-400 text-zinc-950 font-semibold text-xs">
                  <Icons.send class="w-3.5 h-3.5 mr-1.5" /> Message
                </.button>
                <%= if dm[:state] in ["online", "busy"] do %>
                  <.button
                    variant="outline"
                    phx-click="kick_agent"
                    phx-value-agent-id={@selected_agent}
                    data-confirm={"Disconnect #{dm[:name] || @selected_agent} from the fleet?"}
                    class="text-xs border-red-500/30 text-red-400 hover:bg-red-500/10 hover:text-red-300"
                  >
                    <Icons.x class="w-3.5 h-3.5 mr-1" /> Kick
                  </.button>
                <% end %>
              </div>
              <%!-- Deregister (danger) --%>
              <.button
                variant="outline"
                phx-click="deregister_agent"
                phx-value-agent-id={@selected_agent}
                data-confirm={"Permanently deregister #{dm[:name] || @selected_agent}? This removes the agent from the database."}
                class="w-full text-xs border-red-500/20 text-red-400/70 hover:bg-red-500/10 hover:text-red-300"
              >
                Deregister Agent
              </.button>

              <.separator />

              <%!-- Recent activity --%>
              <div>
                <div class="text-[10px] font-semibold text-zinc-500 uppercase tracking-wider mb-2">Recent Activity</div>
                <%= if @agent_activities == [] do %>
                  <p class="text-xs text-zinc-600 italic">No activity</p>
                <% else %>
                  <div class="space-y-0.5">
                    <%= for a <- Enum.take(@agent_activities, 8) do %>
                      <Components.activity_item activity={a} compact={true} />
                    <% end %>
                  </div>
                <% end %>
              </div>
            </div>
          <% end %>
        </.sheet_content>
      </.sheet>
    </div>
    """
  end

  # ══════════════════════════════════════════════════════════
  # Page: Activity
  # ══════════════════════════════════════════════════════════

  defp render_activity(assigns) do
    filtered = filtered_activities(assigns.activities, assigns.filter)
    {today, yesterday, older} = group_by_day(filtered)

    assigns = assign(assigns,
      today: today, yesterday: yesterday, older: older,
      total: length(filtered)
    )

    ~H"""
    <div class="h-full flex flex-col overflow-hidden animate-fade-in">
      <div class="px-6 py-4 border-b border-zinc-800 shrink-0">
        <div class="flex items-center justify-between">
          <div>
            <h2 class="text-lg font-semibold text-zinc-100">Activity</h2>
            <p class="text-sm text-zinc-500"><%= @total %> events</p>
          </div>
          <div class="flex rounded-lg border border-zinc-800 p-0.5 bg-zinc-900">
            <%= for {label, value} <- [{"All", "all"}, {"Tasks", "tasks"}, {"Discoveries", "discoveries"}, {"Alerts", "alerts"}, {"Joins", "joins"}] do %>
              <.button
                variant={if(@filter == value, do: "secondary", else: "ghost")}
                size="sm"
                phx-click="set_filter"
                phx-value-filter={value}
                class={"text-[10px] px-2.5 py-1 h-auto rounded-md font-medium " <> if(@filter == value, do: "bg-zinc-800 text-zinc-100", else: "text-zinc-500 hover:text-zinc-300")}
              >
                <%= label %>
              </.button>
            <% end %>
          </div>
        </div>
      </div>

      <div class="flex-1 overflow-y-auto px-6 py-4" id="activity-stream">
        <%= if @total == 0 do %>
          <Components.empty_state message="No events match filter" subtitle="Try a different filter or wait for new events" icon={:activity} />
        <% else %>
          <%= for {label, items} <- [{"Today", @today}, {"Yesterday", @yesterday}, {"Older", @older}], items != [] do %>
            <div class="mb-5">
              <div class="flex items-center gap-3 mb-2">
                <span class="text-xs font-medium text-zinc-400"><%= label %></span>
                <.separator class="flex-1" />
                <.badge variant="secondary" class="text-[10px] text-zinc-600 font-mono bg-transparent"><%= length(items) %></.badge>
              </div>
              <div class="space-y-0.5">
                <%= for a <- items do %>
                  <Components.activity_item activity={a} />
                <% end %>
              </div>
            </div>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  # ══════════════════════════════════════════════════════════
  # Page: Messaging
  # ══════════════════════════════════════════════════════════

  defp render_messaging(assigns) do
    agents_sorted = assigns.agents
      |> Enum.sort_by(fn {_, m} -> Components.state_sort_order(m[:state]) end)

    assigns = assign(assigns, agents_sorted: agents_sorted)

    ~H"""
    <div class="h-full flex animate-fade-in">
      <%!-- Agent list --%>
      <div class="w-56 border-r border-zinc-800 overflow-y-auto shrink-0 bg-zinc-900">
        <div class="p-3">
          <div class="px-2 py-2 text-[10px] font-semibold text-zinc-500 uppercase tracking-wider">Agents</div>
          <%= if map_size(@agents) == 0 do %>
            <p class="px-2 py-3 text-xs text-zinc-600">No agents online</p>
          <% else %>
            <%= for {id, m} <- @agents_sorted do %>
              <button phx-click="select_msg_agent" phx-value-agent-id={id}
                class={"w-full flex items-center gap-2 px-2.5 py-2 rounded-lg text-left transition-colors duration-150 " <> if(@msg_to == id, do: "bg-zinc-800", else: "hover:bg-zinc-800/50")}>
                <span class={"w-1.5 h-1.5 rounded-full " <> Components.state_dot(m[:state])}></span>
                <div class="min-w-0 flex-1">
                  <div class="text-sm text-zinc-200 truncate"><%= m[:name] || id %></div>
                  <div class="text-[10px] text-zinc-600"><%= m[:state] %></div>
                </div>
              </button>
            <% end %>
          <% end %>
        </div>
      </div>

      <%!-- Conversation --%>
      <div class="flex-1 flex flex-col min-w-0">
        <%= if @msg_to do %>
          <% am = Map.get(@agents, @msg_to, %{name: @msg_to}) %>
          <div class="px-4 py-3 border-b border-zinc-800 shrink-0 flex items-center gap-2.5">
            <div class={"w-7 h-7 rounded-lg flex items-center justify-center text-xs font-bold " <> Components.avatar_bg(am[:state])}>
              <%= Components.avatar_initial(am[:name] || @msg_to) %>
            </div>
            <div>
              <div class="text-sm font-medium text-zinc-200"><%= am[:name] || @msg_to %></div>
              <div class="text-[10px] text-zinc-500"><%= am[:state] || "offline" %></div>
            </div>
          </div>

          <div class="flex-1 overflow-y-auto px-4 py-4" id="msg-thread" phx-hook="ScrollBottom">
            <%= if @messages == [] do %>
              <div class="flex flex-col items-center justify-center h-full text-center">
                <div class="w-12 h-12 rounded-2xl bg-zinc-800 flex items-center justify-center mb-3">
                  <Icons.message_square class="w-5 h-5 text-zinc-600" />
                </div>
                <p class="text-sm text-zinc-500">No messages yet</p>
                <p class="text-xs text-zinc-600 mt-0.5">Send the first message below</p>
              </div>
            <% else %>
              <%= for msg <- @messages do %>
                <Components.message_bubble msg={msg} />
              <% end %>
            <% end %>
          </div>

          <div class="px-4 py-3 border-t border-zinc-800 shrink-0">
            <form phx-submit="send_message" class="flex gap-2">
              <input type="hidden" name="to" value={@msg_to} />
              <.input type="text" name="body" value={@msg_body} phx-keyup="update_msg_body"
                placeholder={"Message " <> (am[:name] || @msg_to) <> "..."} autocomplete="off"
                class="flex-1 bg-zinc-900 border-zinc-800 text-zinc-100 placeholder:text-zinc-600 focus:border-zinc-600" />
              <.button type="submit"
                class="bg-amber-500 hover:bg-amber-400 text-zinc-950 font-semibold text-xs shrink-0">
                <Icons.send class="w-3.5 h-3.5 mr-1" /> Send
              </.button>
            </form>
          </div>
        <% else %>
          <div class="flex-1 flex items-center justify-center">
            <div class="text-center">
              <div class="w-14 h-14 rounded-2xl bg-zinc-800 flex items-center justify-center mb-4 mx-auto">
                <Icons.message_square class="w-6 h-6 text-zinc-600" />
              </div>
              <p class="font-medium text-zinc-400">Select an agent</p>
              <p class="text-sm text-zinc-500 mt-1">Choose from the list to start messaging</p>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # ══════════════════════════════════════════════════════════
  # Page: Quotas
  # ══════════════════════════════════════════════════════════

  defp render_quotas(assigns) do
    plan_limits = Hub.Quota.plan_limits()
    assigns = assign(assigns, plan_limits: plan_limits)

    ~H"""
    <div class="h-full overflow-y-auto p-6 animate-fade-in">
      <div class="max-w-3xl">
        <div class="mb-6">
          <h2 class="text-lg font-semibold text-zinc-100">Quotas & Metrics</h2>
          <p class="text-sm text-zinc-500">Resource usage and plan limits</p>
        </div>

        <%!-- Plan card --%>
        <.card class="bg-zinc-900 border-zinc-800 mb-6">
          <.card_content class="p-4 flex items-center justify-between">
            <div class="flex items-center gap-3">
              <div class="p-2 rounded-lg bg-amber-500/15">
                <Icons.zap class="w-5 h-5 text-amber-400" />
              </div>
              <div>
                <div class="text-sm font-semibold text-zinc-100 capitalize"><%= @plan %> Plan</div>
                <div class="text-xs text-zinc-500">Tenant: <%= String.slice(@tenant_id, 0, 8) %>…</div>
              </div>
            </div>
            <div class="text-right">
              <div class="text-[10px] text-zinc-500">Fleet</div>
              <div class="text-sm font-medium text-zinc-300"><%= @fleet_name %></div>
            </div>
          </.card_content>
        </.card>

        <%!-- Quota cards --%>
        <div class="grid grid-cols-2 gap-3 mb-6">
          <%= for {resource, label, icon, color} <- Components.quota_resources() do %>
            <% info = Map.get(@usage, resource, %{used: 0, limit: 0}) %>
            <Components.quota_card label={label} icon={icon} info={info} color={color} />
          <% end %>
        </div>

        <%!-- Plan comparison --%>
        <.card class="bg-zinc-900 border-zinc-800 mb-6">
          <.card_header class="pb-2">
            <.card_title class="text-sm font-medium text-zinc-300">Plan Limits</.card_title>
          </.card_header>
          <.card_content>
            <.table>
              <.table_header>
                <.table_row class="border-zinc-800 hover:bg-transparent">
                  <.table_head class="text-zinc-500 text-[10px] uppercase tracking-wider">Resource</.table_head>
                  <%= for p <- ["free", "team", "enterprise"] do %>
                    <.table_head class={"text-center text-[10px] uppercase tracking-wider " <> if(@plan == p, do: "text-amber-400", else: "text-zinc-500")}>
                      <%= p %><%= if @plan == p, do: " ●", else: "" %>
                    </.table_head>
                  <% end %>
                </.table_row>
              </.table_header>
              <.table_body>
                <%= for {resource, label, _icon, _color} <- Components.quota_resources() do %>
                  <.table_row class="border-zinc-800/50">
                    <.table_cell class="text-zinc-400"><%= label %></.table_cell>
                    <%= for p <- ["free", "team", "enterprise"] do %>
                      <% limits = Map.get(@plan_limits, p, %{}) %>
                      <.table_cell class={"text-center font-mono " <> if(@plan == p, do: "text-amber-400", else: "text-zinc-400")}>
                        <%= Components.fmt_limit(Map.get(limits, resource, 0)) %>
                      </.table_cell>
                    <% end %>
                  </.table_row>
                <% end %>
              </.table_body>
            </.table>
          </.card_content>
        </.card>

        <%!-- Usage Summary --%>
        <.card class="bg-zinc-900 border-zinc-800">
          <.card_header class="pb-2">
            <.card_title class="text-sm font-medium text-zinc-300">Usage Summary</.card_title>
          </.card_header>
          <.card_content>
            <div class="grid grid-cols-2 gap-4">
              <%= for {resource, label, _icon, color} <- Components.quota_resources() do %>
                <% info = Map.get(@usage, resource, %{used: 0, limit: 0}) %>
                <% pct = Components.quota_pct(info) %>
                <div class="text-center p-3 rounded-lg bg-zinc-800/30">
                  <div class={"text-2xl font-bold " <> if(pct >= 80, do: "text-amber-400", else: "text-zinc-200")}><%= Components.fmt_num(info[:used] || 0) %></div>
                  <div class="text-[10px] text-zinc-500 mt-0.5"><%= label %></div>
                  <div class="mt-2 h-1 bg-zinc-800 rounded-full overflow-hidden">
                    <div class={"h-full rounded-full " <> Components.bar_color(pct)} style={"width: #{max(pct, 1)}%"}></div>
                  </div>
                  <div class="text-[10px] text-zinc-600 mt-1"><%= pct %>% of <%= Components.fmt_limit(info[:limit] || 0) %></div>
                </div>
              <% end %>
            </div>
          </.card_content>
        </.card>
      </div>
    </div>
    """
  end

  # ══════════════════════════════════════════════════════════
  # Page: Settings
  # ══════════════════════════════════════════════════════════

  defp render_settings(assigns) do
    ~H"""
    <div class="h-full overflow-y-auto p-6 animate-fade-in">
      <div class="max-w-2xl">
        <div class="mb-6">
          <h2 class="text-lg font-semibold text-zinc-100">Settings</h2>
          <p class="text-sm text-zinc-500">Fleet configuration and API key management</p>
        </div>

        <%!-- Fleet Info (editable) --%>
        <.card class="bg-zinc-900 border-zinc-800 mb-4">
          <.card_header class="pb-2">
            <div class="flex items-center justify-between">
              <.card_title class="text-sm font-medium text-zinc-300">Fleet Information</.card_title>
            </div>
          </.card_header>
          <.card_content>
            <div class="space-y-0 text-xs divide-y divide-zinc-800/50">
              <%!-- Fleet Name — editable --%>
              <div class="flex items-center justify-between py-2.5">
                <span class="text-zinc-500">Fleet Name</span>
                <%= if @editing_fleet_name do %>
                  <form phx-submit="rename_fleet" class="flex items-center gap-2">
                    <input type="text" name="name" value={@fleet_name} autofocus
                      class="h-7 px-2 text-[11px] bg-zinc-800 border border-zinc-700 rounded text-zinc-200 focus:border-amber-500/50 focus:outline-none w-40" />
                    <.button type="submit" variant="ghost" size="sm" class="h-7 px-2 text-[10px] text-amber-400 hover:text-amber-300">Save</.button>
                    <.button type="button" variant="ghost" size="sm" phx-click="cancel_edit_fleet_name" class="h-7 px-2 text-[10px] text-zinc-500 hover:text-zinc-300">Cancel</.button>
                  </form>
                <% else %>
                  <div class="flex items-center gap-2">
                    <span class="text-zinc-300 font-mono text-[11px]"><%= @fleet_name %></span>
                    <button phx-click="edit_fleet_name" class="text-zinc-600 hover:text-amber-400 transition-colors" title="Edit name">
                      <Icons.pencil class="w-3 h-3" />
                    </button>
                  </div>
                <% end %>
              </div>
              <%= for {label, val} <- [{"Fleet ID", @fleet_id}, {"Tenant ID", @tenant_id}] do %>
                <div class="flex justify-between py-2.5">
                  <span class="text-zinc-500"><%= label %></span>
                  <span class="text-zinc-300 font-mono text-[11px]"><%= val %></span>
                </div>
              <% end %>
              <div class="flex justify-between py-2.5">
                <span class="text-zinc-500">Plan</span>
                <.badge variant="outline" class="text-amber-400 border-amber-500/20 font-medium capitalize"><%= @plan %></.badge>
              </div>
              <div class="flex justify-between py-2.5">
                <span class="text-zinc-500">Agents</span>
                <span class="text-zinc-300"><%= map_size(@agents) %> connected</span>
              </div>
            </div>
          </.card_content>
        </.card>

        <%!-- Claim Account (only if no email set) --%>
        <%= unless @tenant_email do %>
          <.card class="bg-zinc-900 border-amber-500/30 mb-4 animate-fade-in">
            <.card_header class="pb-2">
              <div class="flex items-center gap-2">
                <div class="w-8 h-8 rounded-lg bg-amber-500/15 flex items-center justify-center">
                  <Icons.user_plus class="w-4 h-4 text-amber-400" />
                </div>
                <div>
                  <.card_title class="text-sm font-medium text-zinc-300">Set Up Login</.card_title>
                  <.card_description class="text-[11px]">Add email & password so you can sign in without an API key</.card_description>
                </div>
              </div>
            </.card_header>
            <.card_content>
              <form phx-submit="claim_account" class="space-y-3">
                <div>
                  <label class="text-[11px] text-zinc-400 mb-1 block font-medium">Email</label>
                  <.input
                    type="email"
                    name="email"
                    placeholder="you@example.com"
                    autocomplete="email"
                    required
                    class="w-full bg-zinc-950 border-zinc-700 text-zinc-100 placeholder:text-zinc-600 focus:border-amber-500/50 h-9 text-xs"
                  />
                </div>
                <div>
                  <label class="text-[11px] text-zinc-400 mb-1 block font-medium">Password</label>
                  <.input
                    type="password"
                    name="password"
                    placeholder="Min. 8 characters"
                    autocomplete="new-password"
                    required
                    minlength="8"
                    class="w-full bg-zinc-950 border-zinc-700 text-zinc-100 placeholder:text-zinc-600 focus:border-amber-500/50 h-9 text-xs"
                  />
                </div>
                <.button
                  type="submit"
                  class="w-full bg-amber-500 hover:bg-amber-400 text-zinc-950 font-semibold h-9 text-xs"
                >
                  Claim Account
                </.button>
              </form>
            </.card_content>
          </.card>
        <% end %>

        <%!-- Account info (when email is set) --%>
        <%= if @tenant_email do %>
          <.card class="bg-zinc-900 border-zinc-800 mb-4">
            <.card_header class="pb-2">
              <.card_title class="text-sm font-medium text-zinc-300">Account</.card_title>
            </.card_header>
            <.card_content>
              <div class="flex items-center justify-between py-2 text-xs">
                <span class="text-zinc-500">Email</span>
                <span class="text-zinc-300 font-mono text-[11px]"><%= @tenant_email %></span>
              </div>
            </.card_content>
          </.card>
        <% end %>

        <%!-- API Keys --%>
        <.card class="bg-zinc-900 border-zinc-800 mb-4">
          <.card_header class="pb-2">
            <.card_title class="text-sm font-medium text-zinc-300">API Keys</.card_title>
            <.card_description>Rotate keys to revoke all existing keys of that type and generate a new one</.card_description>
          </.card_header>
          <.card_content>
            <%!-- New key alert --%>
            <%= if @new_api_key do %>
              <div class="mb-4 p-3 rounded-lg border border-amber-500/30 bg-amber-500/10 animate-fade-in">
                <div class="flex items-center justify-between mb-1.5">
                  <span class="text-xs font-semibold text-amber-400">New <%= @new_api_key_type %> key generated</span>
                  <button phx-click="dismiss_new_key" class="text-zinc-500 hover:text-zinc-300">
                    <Icons.x class="w-3.5 h-3.5" />
                  </button>
                </div>
                <div class="flex items-center gap-2">
                  <code class="text-[11px] text-zinc-200 font-mono block break-all select-all bg-zinc-900/50 rounded p-2 flex-1"><%= @new_api_key %></code>
                  <button phx-hook="CopyKey" id="copy-key-btn" data-key={@new_api_key} class="shrink-0 text-[10px] text-zinc-400 hover:text-amber-400 px-2 py-1 rounded border border-zinc-700 hover:border-amber-500/30 transition-colors">
                    Copy
                  </button>
                </div>
                <p class="text-[10px] text-amber-400/70 mt-1.5">⚠ Save this key now — it will not be shown again</p>
              </div>
            <% end %>

            <div class="space-y-2">
              <%= for {type, desc, color} <- [{"live", "Agent connections", "green"}, {"test", "Testing & development", "blue"}, {"admin", "Dashboard & admin API", "amber"}] do %>
                <div class="flex items-center justify-between py-2 px-3 rounded-lg hover:bg-zinc-800/50 transition-colors">
                  <div class="flex items-center gap-3">
                    <div class={"w-2 h-2 rounded-full bg-#{color}-400"}></div>
                    <div>
                      <div class="text-xs font-medium text-zinc-200 capitalize"><%= type %></div>
                      <div class="text-[10px] text-zinc-600"><%= desc %></div>
                    </div>
                  </div>
                  <.button
                    variant="outline"
                    size="sm"
                    phx-click="rotate_api_key"
                    phx-value-type={type}
                    data-confirm={"Rotate #{type} key? All existing #{type} keys will be revoked."}
                    class="h-7 text-[10px] border-zinc-700 text-zinc-400 hover:text-amber-400 hover:border-amber-500/30"
                  >
                    Rotate
                  </.button>
                </div>
              <% end %>
            </div>
          </.card_content>
        </.card>

        <%!-- Connection --%>
        <.card class="bg-zinc-900 border-zinc-800 mb-4">
          <.card_header class="pb-2">
            <.card_title class="text-sm font-medium text-zinc-300">Connection</.card_title>
          </.card_header>
          <.card_content>
            <div class="space-y-0 text-xs divide-y divide-zinc-800/50">
              <div class="flex justify-between py-2.5">
                <span class="text-zinc-500">WebSocket</span>
                <div class="flex items-center gap-1.5">
                  <span class="w-1.5 h-1.5 rounded-full bg-green-400 animate-pulse-dot"></span>
                  <span class="text-green-400">Connected</span>
                </div>
              </div>
              <div class="flex justify-between py-2.5">
                <span class="text-zinc-500">PubSub</span>
                <span class="text-zinc-300 font-mono text-[11px]">fleet:<%= @fleet_id %></span>
              </div>
              <div class="flex justify-between py-2.5">
                <span class="text-zinc-500">Quota refresh</span>
                <span class="text-zinc-300">5s interval</span>
              </div>
            </div>
          </.card_content>
        </.card>

        <%!-- Keyboard shortcuts --%>
        <.card class="bg-zinc-900 border-zinc-800">
          <.card_header class="pb-2">
            <.card_title class="text-sm font-medium text-zinc-300">Keyboard Shortcuts</.card_title>
          </.card_header>
          <.card_content>
            <div class="grid grid-cols-2 gap-1.5 text-xs">
              <%= for {key, desc} <- [{"⌘K", "Command palette"}, {"1", "Dashboard"}, {"2", "Agents"}, {"3", "Activity"}, {"4", "Messaging"}, {"5", "Quotas"}, {"6", "Settings"}] do %>
                <div class="flex items-center gap-2 py-1.5">
                  <kbd class="px-1.5 py-0.5 rounded bg-zinc-800 border border-zinc-700 text-zinc-400 text-[10px] font-mono min-w-[24px] text-center"><%= key %></kbd>
                  <span class="text-zinc-500"><%= desc %></span>
                </div>
              <% end %>
            </div>
          </.card_content>
        </.card>
      </div>
    </div>
    """
  end

  # ══════════════════════════════════════════════════════════
  # Authentication
  # ══════════════════════════════════════════════════════════

  defp authenticate(params, session) do
    cond do
      key = params["key"] -> validate_admin_key(key)
      tenant_id = session["tenant_id"] ->
        fleet = load_default_fleet(tenant_id)
        tenant = Hub.Repo.get(Hub.Auth.Tenant, tenant_id)
        plan = if(tenant, do: tenant.plan || "free", else: "free")
        email = if(tenant, do: tenant.email, else: nil)
        if fleet, do: {:ok, tenant_id, fleet.id, fleet.name, plan, email}, else: {:error, :unauthenticated}
      true -> {:error, :unauthenticated}
    end
  end

  defp validate_admin_key(raw_key) do
    case Hub.Auth.validate_api_key(raw_key) do
      {:ok, %{type: "admin", tenant_id: tenant_id}} ->
        fleet = load_default_fleet(tenant_id)
        tenant = Hub.Repo.get(Hub.Auth.Tenant, tenant_id)
        plan = if(tenant, do: tenant.plan || "free", else: "free")
        email = if(tenant, do: tenant.email, else: nil)
        if fleet, do: {:ok, tenant_id, fleet.id, fleet.name, plan, email}, else: {:error, :no_fleet}
      {:ok, _} -> {:error, :not_admin}
      {:error, reason} -> {:error, reason}
    end
  end

  # ══════════════════════════════════════════════════════════
  # Data Loading
  # ══════════════════════════════════════════════════════════

  defp load_default_fleet(tenant_id) do
    import Ecto.Query
    Hub.Repo.one(from f in Hub.Auth.Fleet, where: f.tenant_id == ^tenant_id, order_by: [asc: f.inserted_at], limit: 1)
  end

  defp load_agents(fleet_id) do
    case FleetPresence.list("fleet:#{fleet_id}") do
      p when is_map(p) -> Map.new(p, fn {id, %{metas: [m | _]}} -> {id, normalize_meta(m)} end)
      _ -> %{}
    end
  end

  defp normalize_meta(m) do
    %{
      name: m[:name] || m["name"],
      state: m[:state] || m["state"] || "online",
      capabilities: m[:capabilities] || m["capabilities"] || [],
      task: m[:task] || m["task"],
      framework: m[:framework] || m["framework"],
      connected_at: m[:connected_at] || m["connected_at"]
    }
  end

  defp load_recent_activities(fleet_id) do
    case Hub.EventBus.replay("ringforge.#{fleet_id}.activity", limit: @activity_limit) do
      {:ok, events} ->
        events
        |> Enum.map(fn e ->
          %{
            kind: e["kind"] || "custom",
            agent_id: get_in(e, ["from", "agent_id"]) || "unknown",
            agent_name: get_in(e, ["from", "name"]) || "unknown",
            description: e["description"] || "",
            tags: e["tags"] || [],
            timestamp: e["timestamp"] || ""
          }
        end)
        |> Enum.reverse()
      {:error, _} -> []
    end
  end

  defp load_usage(tenant_id), do: Hub.Quota.get_usage(tenant_id)

  defp load_registered_agents(tenant_id) do
    import Ecto.Query
    from(a in Hub.Auth.Agent,
      where: a.tenant_id == ^tenant_id,
      order_by: [desc: a.inserted_at],
      preload: [:fleet]
    ) |> Hub.Repo.all()
  end

  defp load_conversation(fleet_id, agent_id) do
    case Hub.DirectMessage.history(fleet_id, "dashboard", agent_id, limit: 50) do
      {:ok, msgs} -> msgs
      {:error, _} -> []
    end
  end

  # ══════════════════════════════════════════════════════════
  # Hub Event Handler
  # ══════════════════════════════════════════════════════════

  defp handle_hub_event(%{type: :activity_published, payload: p}, socket) do
    if p[:fleet_id] == socket.assigns.fleet_id do
      activity = %{
        kind: p[:kind] || "custom", agent_id: p[:agent_id] || "unknown",
        agent_name: p[:agent_name] || "unknown", description: p[:description] || "",
        tags: p[:tags] || [],
        timestamp: p[:timestamp] || DateTime.utc_now() |> DateTime.to_iso8601()
      }
      assign(socket, activities: prepend_activity(socket.assigns.activities, activity))
    else
      socket
    end
  end
  defp handle_hub_event(_, socket), do: socket

  # ══════════════════════════════════════════════════════════
  # Helpers
  # ══════════════════════════════════════════════════════════

  defp prepend_activity(activities, a), do: [a | activities] |> Enum.take(@activity_limit)

  defp filtered_activities(a, "all"), do: a
  defp filtered_activities(a, "tasks"), do: Enum.filter(a, &(&1.kind in ~w(task_started task_progress task_completed task_failed)))
  defp filtered_activities(a, "discoveries"), do: Enum.filter(a, &(&1.kind == "discovery"))
  defp filtered_activities(a, "alerts"), do: Enum.filter(a, &(&1.kind in ~w(alert question)))
  defp filtered_activities(a, "joins"), do: Enum.filter(a, &(&1.kind in ~w(join leave)))
  defp filtered_activities(a, _), do: a

  defp filter_agent_activities(activities, agent_id), do: Enum.filter(activities, &(&1.agent_id == agent_id))

  defp group_by_day(activities) do
    today = Date.utc_today()
    yesterday = Date.add(today, -1)
    Enum.reduce(activities, {[], [], []}, fn a, {t, y, o} ->
      case parse_date(a.timestamp) do
        ^today -> {t ++ [a], y, o}
        ^yesterday -> {t, y ++ [a], o}
        _ -> {t, y, o ++ [a]}
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

  defp filter_agents(agents, ""), do: agents
  defp filter_agents(agents, nil), do: agents
  defp filter_agents(agents, q) do
    q = String.downcase(q)
    Enum.filter(agents, fn {id, m} ->
      String.contains?(String.downcase(id), q) ||
      String.contains?(String.downcase(m[:name] || ""), q) ||
      String.contains?(String.downcase(m[:framework] || ""), q) ||
      Enum.any?(List.wrap(m[:capabilities] || []), &String.contains?(String.downcase(&1), q))
    end)
  end

  defp sort_agents(a, :name, dir), do: Enum.sort_by(a, fn {_, m} -> String.downcase(m[:name] || "") end, dir)
  defp sort_agents(a, :state, dir), do: Enum.sort_by(a, fn {_, m} -> Components.state_sort_order(m[:state]) end, dir)
  defp sort_agents(a, :framework, dir), do: Enum.sort_by(a, fn {_, m} -> String.downcase(m[:framework] || "zzz") end, dir)
  defp sort_agents(a, _, _), do: a

  defp sort_arrow(current, dir, col) when current == col, do: if(dir == :asc, do: "↑", else: "↓")
  defp sort_arrow(_, _, _), do: ""
end
