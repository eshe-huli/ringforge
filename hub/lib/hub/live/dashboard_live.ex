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
  alias Phoenix.LiveView.JS
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
          messaging_tab: "dms",
          msg_access_result: nil,
          threads: [],
          selected_thread: nil,
          thread_messages: [],
          escalations: [],
          escalation_action: nil,
          escalation_action_id: nil,
          escalation_forward_to: nil,
          escalation_response: "",
          announcements: [],
          announcement_form: %{scope: "fleet", body: "", priority: "normal"},
          registered_agents_detail: [],
          agent_kanban_tasks: [],
          agent_role_editing: false,
          agent_squad_editing: false,
          available_roles: [],
          available_squads: [],
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
          active_keys: [],
          authenticated: true,
          wizard_open: false,
          wizard_step: 1,
          wizard_framework: nil,
          wizard_agent_name: "",
          wizard_live_key: nil,
          wizard_waiting: false,
          wizard_connected_agent: nil,
          wizard_agent_count_at_open: 0,
          theme: "system",
          # Fleet management
          tenant_fleets: [],
          selected_fleet_id: nil,
          fleet_detail: nil,
          fleet_detail_squads: [],
          fleet_form_open: false,
          fleet_form_mode: :create,
          fleet_form_name: "",
          fleet_form_description: "",
          fleet_form_id: nil,
          squad_form_open: false,
          squad_form_name: "",
          squad_form_fleet_id: nil,
          assign_agent_fleet_open: false,
          # Squad management view
          squads: [],
          selected_squad: nil,
          selected_squad_members: [],
          selected_squad_memory: [],
          selected_squad_activity: [],
          squad_create_form_open: false,
          squad_view_form_name: "",
          squad_view_form_description: "",
          squad_view_form_capabilities: [],
          squad_memory_filter: "",
          squad_capability_input: "",
          squad_detail_tab: "members",
          assign_agent_fleet_agent_id: nil,
          # Kanban board
          kanban_board: %{"backlog" => [], "ready" => [], "in_progress" => [], "review" => [], "done" => []},
          kanban_stats: %{},
          kanban_selected_task: nil,
          kanban_detail_open: false,
          kanban_create_open: false,
          kanban_task_history: [],
          kanban_filters: %{squad_id: nil, assigned_to: nil, priority: nil, search: ""},
          kanban_form: %{
            title: "",
            description: "",
            priority: "medium",
            effort: "medium",
            assigned_to: "",
            squad_id: "",
            acceptance_criteria: [],
            new_criterion: ""
          },
          kanban_squads: [],
          kanban_edit_mode: false,
          kanban_progress_pct: 0,
          selected_task_artifacts: [],
          selected_task_threads: [],
          # Roles management
          roles: [],
          selected_role: nil,
          role_detail_open: false,
          role_form_open: false,
          role_form: %{
            name: "",
            slug: "",
            system_prompt: "",
            capabilities: [],
            constraints: [],
            tools_allowed: [],
            escalation_rules: "",
            context_injection_tier: "auto",
            new_capability: "",
            new_constraint: "",
            new_tool: ""
          },
          role_form_mode: :create,
          role_form_id: nil,
          role_assign_agent_id: nil
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
        active_keys = load_active_keys(tenant_id)
        tenant_fleets = Hub.Fleets.list_fleets(tenant_id)

        {:ok, assign(socket, agents: agents, activities: activities, usage: usage, registered_agents: registered, active_keys: active_keys, tenant_fleets: tenant_fleets)}

      {:error, :unauthenticated} ->
        # Read error/tab from URL params (set by SessionController redirect)
        auth_error = params["error"]
        auth_tab = params["tab"] || "login"
        invite_code = params["invite"] || ""
        {:ok, assign(socket,
          authenticated: false,
          auth_error: auth_error,
          auth_tab: auth_tab,
          key_input: "",
          register_name: "",
          register_email: "",
          login_email: "",
          magic_link_email: "",
          invite_code: invite_code,
          invite_only: Hub.Invites.invite_only?()
        )}
    end
  end

  # ══════════════════════════════════════════════════════════
  # Events
  # ══════════════════════════════════════════════════════════

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  # Auth tab switching
  @impl true
  def handle_event("switch_auth_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, auth_tab: tab, auth_error: nil)}
  end

  # Claim account — set email/password on existing tenant
  def handle_event("claim_account", %{"admin_key" => key, "email" => email, "password" => password}, socket) do
    # Verify admin key belongs to this tenant before allowing claim
    case Hub.Auth.validate_api_key(key) do
      {:ok, %{type: "admin", tenant_id: tenant_id}} when tenant_id == socket.assigns.tenant_id ->
        tenant = Hub.Repo.get(Hub.Auth.Tenant, tenant_id)

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

      _ ->
        {:noreply, assign(socket, toast: {:error, "Invalid admin API key"})}
    end
  end

  # Navigation
  def handle_event("navigate", %{"view" => "billing"}, socket) do
    {:noreply, redirect(socket, to: "/billing")}
  end

  def handle_event("navigate", %{"view" => "webhooks"}, socket) do
    {:noreply, redirect(socket, to: "/webhooks")}
  end

  def handle_event("navigate", %{"view" => "metrics"}, socket) do
    {:noreply, redirect(socket, to: "/dashboard/metrics")}
  end

  def handle_event("navigate", %{"view" => "provisioning"}, socket) do
    {:noreply, redirect(socket, to: "/provisioning")}
  end

  def handle_event("navigate", %{"view" => view} = params, socket) do
    socket = assign(socket, current_view: view, cmd_open: false, cmd_query: "")

    socket = if view == "agents" do
      registered = load_registered_agents_detail(socket.assigns.fleet_id)
      roles = Hub.Roles.list_roles(socket.assigns.tenant_id)
      squads = try do Hub.Fleets.list_squads(socket.assigns.fleet_id) rescue _ -> [] end

      base = assign(socket,
        registered_agents_detail: registered,
        available_roles: roles,
        available_squads: squads,
        agent_role_editing: false,
        agent_squad_editing: false
      )

      if params["agent"] do
        assign(base,
          selected_agent: params["agent"],
          agent_detail_open: true,
          agent_activities: filter_agent_activities(base.assigns.activities, params["agent"]),
          agent_kanban_tasks: load_agent_kanban_tasks(params["agent"], base.assigns.fleet_id)
        )
      else
        base
      end
    else
      socket
    end

    socket = if view == "messaging" do
      base = assign(socket, messaging_tab: "dms", msg_access_result: nil)
      if params["agent"] do
        messages = load_conversation(base.assigns.fleet_id, params["agent"])
        assign(base, msg_to: params["agent"], messages: messages)
      else
        base
      end
    else
      socket
    end

    socket = if view == "kanban" do
      load_kanban_board(socket)
    else
      socket
    end

    socket = if view == "roles" do
      roles = Hub.Roles.list_roles(socket.assigns.tenant_id)
      assign(socket, roles: roles, selected_role: nil, role_detail_open: false, role_form_open: false)
    else
      socket
    end

    socket = if view == "squads" do
      squads = load_squads_for_fleet(socket.assigns.fleet_id)
      assign(socket,
        squads: squads,
        selected_squad: nil,
        selected_squad_members: [],
        selected_squad_memory: [],
        selected_squad_activity: [],
        squad_create_form_open: false,
        squad_view_form_name: "",
        squad_view_form_description: "",
        squad_view_form_capabilities: [],
        squad_memory_filter: "",
        squad_capability_input: "",
        squad_detail_tab: "members"
      )
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
      agent_activities: filter_agent_activities(socket.assigns.activities, agent_id),
      agent_kanban_tasks: load_agent_kanban_tasks(agent_id, socket.assigns.fleet_id),
      agent_role_editing: false,
      agent_squad_editing: false
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

  # ── Messaging Tab Events ──────────────────────────────────────

  def handle_event("switch_messaging_tab", %{"tab" => tab}, socket) do
    fleet_id = socket.assigns.fleet_id

    socket = case tab do
      "threads" ->
        threads = Hub.Messaging.Threads.list_threads(fleet_id, status: "open")
        assign(socket, messaging_tab: tab, threads: threads)

      "escalations" ->
        # Load pending escalations — dashboard user acts as tier-0 handler
        escalations = Hub.Messaging.Escalation.list_pending(fleet_id, "dashboard")
        assign(socket, messaging_tab: tab, escalations: escalations)

      "announcements" ->
        case Hub.Messaging.Announcements.history(fleet_id) do
          {:ok, anns} -> assign(socket, messaging_tab: tab, announcements: anns)
          _ -> assign(socket, messaging_tab: tab, announcements: [])
        end

      _ ->
        assign(socket, messaging_tab: tab)
    end

    {:noreply, socket}
  end

  # Thread events
  def handle_event("select_thread", %{"thread-id" => thread_id}, socket) do
    case Hub.Messaging.Threads.thread_messages(thread_id) do
      {:ok, msgs} ->
        {:noreply, assign(socket, selected_thread: thread_id, thread_messages: msgs)}
      _ ->
        {:noreply, assign(socket, selected_thread: thread_id, thread_messages: [])}
    end
  end

  def handle_event("create_thread", %{"subject" => subject, "scope" => scope}, socket) do
    fleet_id = socket.assigns.fleet_id
    tenant_id = socket.assigns.tenant_id

    case Hub.Messaging.Threads.create_thread(%{
      subject: subject,
      scope: scope,
      fleet_id: fleet_id,
      tenant_id: tenant_id,
      created_by: "dashboard",
      participant_ids: ["dashboard"]
    }) do
      {:ok, _thread} ->
        threads = Hub.Messaging.Threads.list_threads(fleet_id, status: "open")
        {:noreply, assign(socket, threads: threads, toast: {:success, "Thread created"})}
      {:error, _} ->
        {:noreply, assign(socket, toast: {:error, "Failed to create thread"})}
    end
  end

  def handle_event("send_thread_message", %{"body" => body}, socket) do
    thread_id = socket.assigns.selected_thread
    if thread_id && String.trim(body) != "" do
      case Hub.Messaging.Threads.add_message(thread_id, "dashboard", %{body: body}) do
        {:ok, _msg} ->
          {:ok, msgs} = Hub.Messaging.Threads.thread_messages(thread_id)
          {:noreply, assign(socket, thread_messages: msgs)}
        {:error, _} ->
          {:noreply, assign(socket, toast: {:error, "Failed to send message"})}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("close_thread", %{"thread-id" => thread_id}, socket) do
    case Hub.Messaging.Threads.close_thread(thread_id, "dashboard", "Closed from dashboard") do
      {:ok, _} ->
        threads = Hub.Messaging.Threads.list_threads(socket.assigns.fleet_id, status: "open")
        {:noreply, assign(socket, threads: threads, selected_thread: nil, thread_messages: [], toast: {:success, "Thread closed"})}
      {:error, _} ->
        {:noreply, assign(socket, toast: {:error, "Failed to close thread"})}
    end
  end

  # Escalation events
  def handle_event("escalation_action", %{"action" => action, "id" => id}, socket) do
    {:noreply, assign(socket, escalation_action: action, escalation_action_id: id, escalation_response: "")}
  end

  def handle_event("cancel_escalation_action", _, socket) do
    {:noreply, assign(socket, escalation_action: nil, escalation_action_id: nil, escalation_response: "")}
  end

  def handle_event("escalation_forward_select", %{"agent" => agent_id}, socket) do
    {:noreply, assign(socket, escalation_forward_to: agent_id)}
  end

  def handle_event("submit_escalation_forward", _, socket) do
    esc_id = socket.assigns.escalation_action_id
    to = socket.assigns.escalation_forward_to
    if esc_id && to do
      Hub.Messaging.Escalation.forward_escalation(esc_id, "dashboard", to)
      escalations = Hub.Messaging.Escalation.list_pending(socket.assigns.fleet_id, "dashboard")
      {:noreply, assign(socket, escalations: escalations, escalation_action: nil, escalation_action_id: nil, toast: {:success, "Escalation forwarded"})}
    else
      {:noreply, socket}
    end
  end

  def handle_event("submit_escalation_handle", %{"response" => response}, socket) do
    esc_id = socket.assigns.escalation_action_id
    if esc_id do
      Hub.Messaging.Escalation.handle_escalation(esc_id, "dashboard", response)
      escalations = Hub.Messaging.Escalation.list_pending(socket.assigns.fleet_id, "dashboard")
      {:noreply, assign(socket, escalations: escalations, escalation_action: nil, escalation_action_id: nil, toast: {:success, "Escalation handled"})}
    else
      {:noreply, socket}
    end
  end

  def handle_event("submit_escalation_reject", %{"reason" => reason}, socket) do
    esc_id = socket.assigns.escalation_action_id
    if esc_id do
      Hub.Messaging.Escalation.reject_escalation(esc_id, "dashboard", reason)
      escalations = Hub.Messaging.Escalation.list_pending(socket.assigns.fleet_id, "dashboard")
      {:noreply, assign(socket, escalations: escalations, escalation_action: nil, escalation_action_id: nil, toast: {:success, "Escalation rejected"})}
    else
      {:noreply, socket}
    end
  end

  # Announcement events
  def handle_event("update_announcement_form", params, socket) do
    form = socket.assigns.announcement_form
    form = Map.merge(form, Map.take(params, ["scope", "body", "priority"]) |> Map.new(fn {k,v} -> {String.to_existing_atom(k), v} end))
    {:noreply, assign(socket, announcement_form: form)}
  end

  def handle_event("send_announcement", %{"body" => body, "scope" => scope, "priority" => priority}, socket) do
    fleet_id = socket.assigns.fleet_id
    if String.trim(body) != "" do
      case Hub.Messaging.Announcements.announce(fleet_id, "dashboard", scope, %{body: body, priority: priority}) do
        {:ok, count} ->
          case Hub.Messaging.Announcements.history(fleet_id) do
            {:ok, anns} ->
              {:noreply, assign(socket, announcements: anns, announcement_form: %{scope: "fleet", body: "", priority: "normal"}, toast: {:success, "Announcement sent to #{count} agents"})}
            _ ->
              {:noreply, assign(socket, announcement_form: %{scope: "fleet", body: "", priority: "normal"}, toast: {:success, "Announcement sent to #{count} agents"})}
          end
        {:denied, reason} ->
          {:noreply, assign(socket, toast: {:error, "Denied: #{reason}"})}
        {:error, reason} ->
          {:noreply, assign(socket, toast: {:error, "Failed: #{inspect(reason)}"})}
      end
    else
      {:noreply, socket}
    end
  end

  # Escalate from DM denial
  def handle_event("escalate_from_dm", %{"target" => target_agent_id}, socket) do
    fleet_id = socket.assigns.fleet_id
    case Hub.Messaging.Escalation.create_escalation(fleet_id, "dashboard", "tech-lead", %{
      subject: "DM access request to #{target_agent_id}",
      body: "Dashboard user requested access to DM agent #{target_agent_id} but was denied by access control.",
      priority: "normal"
    }) do
      {:ok, _esc} ->
        Process.send_after(self(), :clear_toast, 4_000)
        {:noreply, assign(socket, msg_access_result: nil, toast: {:success, "Escalation created"})}
      {:error, reason} ->
        {:noreply, assign(socket, toast: {:error, "Escalation failed: #{reason}"})}
    end
  end

  # ── Agent Enhancement Events ────────────────────────────────

  def handle_event("toggle_agent_role_edit", %{"agent-id" => _agent_id}, socket) do
    roles = Hub.Roles.list_roles(socket.assigns.tenant_id)
    {:noreply, assign(socket, agent_role_editing: !socket.assigns.agent_role_editing, available_roles: roles)}
  end

  def handle_event("toggle_agent_squad_edit", %{"agent-id" => _agent_id}, socket) do
    squads = try do Hub.Fleets.list_squads(socket.assigns.fleet_id) rescue _ -> [] end
    {:noreply, assign(socket, agent_squad_editing: !socket.assigns.agent_squad_editing, available_squads: squads)}
  end

  def handle_event("assign_agent_role", %{"agent-id" => agent_id, "role-id" => role_id}, socket) do
    import Ecto.Query
    case Hub.Repo.one(from(a in Hub.Auth.Agent, where: a.agent_id == ^agent_id and a.fleet_id == ^socket.assigns.fleet_id)) do
      nil -> {:noreply, assign(socket, toast: {:error, "Agent not found"})}
      agent ->
        role_id_val = if role_id == "", do: nil, else: role_id
        case Hub.Auth.Agent.changeset(agent, %{role_template_id: role_id_val}) |> Hub.Repo.update() do
          {:ok, _} ->
            registered = load_registered_agents_detail(socket.assigns.fleet_id)
            {:noreply, assign(socket, registered_agents_detail: registered, agent_role_editing: false, toast: {:success, "Role assigned"})}
          {:error, _} ->
            {:noreply, assign(socket, toast: {:error, "Failed to assign role"})}
        end
    end
  end

  def handle_event("assign_agent_squad", %{"agent-id" => agent_id, "squad-id" => squad_id}, socket) do
    import Ecto.Query
    case Hub.Repo.one(from(a in Hub.Auth.Agent, where: a.agent_id == ^agent_id and a.fleet_id == ^socket.assigns.fleet_id)) do
      nil -> {:noreply, assign(socket, toast: {:error, "Agent not found"})}
      agent ->
        squad_id_val = if squad_id == "", do: nil, else: squad_id
        case Hub.Auth.Agent.changeset(agent, %{squad_id: squad_id_val}) |> Hub.Repo.update() do
          {:ok, _} ->
            registered = load_registered_agents_detail(socket.assigns.fleet_id)
            {:noreply, assign(socket, registered_agents_detail: registered, agent_squad_editing: false, toast: {:success, "Squad assigned"})}
          {:error, _} ->
            {:noreply, assign(socket, toast: {:error, "Failed to assign squad"})}
        end
    end
  end

  # ── Fleet Management Events ─────────────────────────────────

  def handle_event("open_fleet_form", %{"mode" => "create"}, socket) do
    {:noreply, assign(socket,
      fleet_form_open: true,
      fleet_form_mode: :create,
      fleet_form_name: "",
      fleet_form_description: "",
      fleet_form_id: nil
    )}
  end

  def handle_event("open_fleet_form", %{"mode" => "edit", "fleet-id" => fleet_id}, socket) do
    fleet = Enum.find(socket.assigns.tenant_fleets, &(&1.id == fleet_id))
    if fleet do
      {:noreply, assign(socket,
        fleet_form_open: true,
        fleet_form_mode: :edit,
        fleet_form_name: fleet.name,
        fleet_form_description: fleet.description || "",
        fleet_form_id: fleet_id
      )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close_fleet_form", _, socket) do
    {:noreply, assign(socket, fleet_form_open: false)}
  end

  def handle_event("fleet_form_name", %{"value" => v}, socket) do
    {:noreply, assign(socket, fleet_form_name: v)}
  end

  def handle_event("fleet_form_description", %{"value" => v}, socket) do
    {:noreply, assign(socket, fleet_form_description: v)}
  end

  def handle_event("save_fleet", _, socket) do
    name = String.trim(socket.assigns.fleet_form_name)
    description = String.trim(socket.assigns.fleet_form_description)

    if name == "" do
      Process.send_after(self(), :clear_toast, 4_000)
      {:noreply, assign(socket, toast: {:error, "Fleet name cannot be empty"})}
    else
      result = case socket.assigns.fleet_form_mode do
        :create ->
          attrs = %{name: name}
          attrs = if description != "", do: Map.put(attrs, :description, description), else: attrs
          Hub.Fleets.create_fleet(socket.assigns.tenant_id, attrs)
        :edit ->
          attrs = %{name: name, description: description}
          Hub.Fleets.update_fleet(socket.assigns.fleet_form_id, attrs)
      end

      case result do
        {:ok, _fleet} ->
          tenant_fleets = Hub.Fleets.list_fleets(socket.assigns.tenant_id)
          action = if socket.assigns.fleet_form_mode == :create, do: "created", else: "updated"
          Process.send_after(self(), :clear_toast, 4_000)
          {:noreply, assign(socket,
            tenant_fleets: tenant_fleets,
            fleet_form_open: false,
            toast: {:success, "Fleet \"#{name}\" #{action}"}
          )}

        {:error, changeset} when is_struct(changeset) ->
          error = Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
                  |> Enum.map_join(". ", fn {field, msgs} -> "#{field}: #{Enum.join(msgs, ", ")}" end)
          Process.send_after(self(), :clear_toast, 4_000)
          {:noreply, assign(socket, toast: {:error, error})}

        {:error, reason} ->
          Process.send_after(self(), :clear_toast, 4_000)
          {:noreply, assign(socket, toast: {:error, "Failed: #{reason}"})}
      end
    end
  end

  def handle_event("delete_fleet", %{"fleet-id" => fleet_id}, socket) do
    case Hub.Fleets.delete_fleet(fleet_id) do
      {:ok, _} ->
        tenant_fleets = Hub.Fleets.list_fleets(socket.assigns.tenant_id)
        # If we were viewing this fleet's detail, clear it
        selected = if socket.assigns.selected_fleet_id == fleet_id, do: nil, else: socket.assigns.selected_fleet_id
        Process.send_after(self(), :clear_toast, 4_000)
        {:noreply, assign(socket,
          tenant_fleets: tenant_fleets,
          selected_fleet_id: selected,
          fleet_detail: nil,
          fleet_detail_squads: [],
          toast: {:success, "Fleet deleted"}
        )}

      {:error, :has_agents} ->
        Process.send_after(self(), :clear_toast, 4_000)
        {:noreply, assign(socket, toast: {:error, "Cannot delete fleet with agents. Move agents first."})}

      {:error, :last_fleet} ->
        Process.send_after(self(), :clear_toast, 4_000)
        {:noreply, assign(socket, toast: {:error, "Cannot delete the last fleet."})}

      {:error, _reason} ->
        Process.send_after(self(), :clear_toast, 4_000)
        {:noreply, assign(socket, toast: {:error, "Failed to delete fleet"})}
    end
  end

  def handle_event("select_fleet", %{"fleet-id" => fleet_id}, socket) do
    case Hub.Fleets.get_fleet(fleet_id) do
      {:ok, fleet, squads} ->
        {:noreply, assign(socket,
          selected_fleet_id: fleet_id,
          fleet_detail: fleet,
          fleet_detail_squads: squads
        )}

      {:error, _} ->
        {:noreply, assign(socket, toast: {:error, "Fleet not found"})}
    end
  end

  def handle_event("close_fleet_detail", _, socket) do
    {:noreply, assign(socket, selected_fleet_id: nil, fleet_detail: nil, fleet_detail_squads: [])}
  end

  # Squad creation
  def handle_event("open_squad_form", %{"fleet-id" => fleet_id}, socket) do
    {:noreply, assign(socket, squad_form_open: true, squad_form_name: "", squad_form_fleet_id: fleet_id)}
  end

  def handle_event("close_squad_form", _, socket) do
    {:noreply, assign(socket, squad_form_open: false)}
  end

  def handle_event("squad_form_name", %{"value" => v}, socket) do
    {:noreply, assign(socket, squad_form_name: v)}
  end

  def handle_event("save_squad", _, socket) do
    name = String.trim(socket.assigns.squad_form_name)
    fleet_id = socket.assigns.squad_form_fleet_id

    if name == "" do
      Process.send_after(self(), :clear_toast, 4_000)
      {:noreply, assign(socket, toast: {:error, "Squad name cannot be empty"})}
    else
      case Hub.Fleets.create_squad(fleet_id, %{name: name}) do
        {:ok, _squad} ->
          # Reload fleet detail and fleet list
          {:ok, fleet, squads} = Hub.Fleets.get_fleet(fleet_id)
          tenant_fleets = Hub.Fleets.list_fleets(socket.assigns.tenant_id)
          Process.send_after(self(), :clear_toast, 4_000)
          {:noreply, assign(socket,
            fleet_detail: fleet,
            fleet_detail_squads: squads,
            tenant_fleets: tenant_fleets,
            squad_form_open: false,
            toast: {:success, "Squad \"#{name}\" created"}
          )}

        {:error, changeset} when is_struct(changeset) ->
          error = Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
                  |> Enum.map_join(". ", fn {field, msgs} -> "#{field}: #{Enum.join(msgs, ", ")}" end)
          Process.send_after(self(), :clear_toast, 4_000)
          {:noreply, assign(socket, toast: {:error, error})}

        {:error, reason} ->
          Process.send_after(self(), :clear_toast, 4_000)
          {:noreply, assign(socket, toast: {:error, "Failed: #{reason}"})}
      end
    end
  end

  # Assign agent to squad (from select dropdown — params include the select name as key)
  def handle_event("assign_to_squad", params, socket) do
    # The select sends params like %{"squad-ag_xxx" => "squad_uuid_here", "agent-id" => "ag_xxx"}
    # Extract agent_id from phx-value and squad_id from the select value
    agent_id = Map.get(params, "agent-id")
    squad_id = params |> Enum.find_value(fn {k, v} -> if String.starts_with?(k, "squad-"), do: v end)

    if is_nil(squad_id) or squad_id == "" do
      {:noreply, socket}
    else
      case Hub.Fleets.assign_agent_to_squad(agent_id, squad_id) do
        {:ok, _agent} ->
          fleet_id = socket.assigns.selected_fleet_id
          {:ok, fleet, squads} = Hub.Fleets.get_fleet(fleet_id)
          Process.send_after(self(), :clear_toast, 4_000)
          {:noreply, assign(socket,
            fleet_detail: fleet,
            fleet_detail_squads: squads,
            toast: {:success, "Agent assigned to squad"}
          )}

        {:error, reason} ->
          Process.send_after(self(), :clear_toast, 4_000)
          {:noreply, assign(socket, toast: {:error, "Failed: #{reason}"})}
      end
    end
  end

  def handle_event("remove_from_squad", %{"agent-id" => agent_id}, socket) do
    case Hub.Fleets.remove_agent_from_squad(agent_id) do
      {:ok, _agent} ->
        fleet_id = socket.assigns.selected_fleet_id
        {:ok, fleet, squads} = Hub.Fleets.get_fleet(fleet_id)
        Process.send_after(self(), :clear_toast, 4_000)
        {:noreply, assign(socket,
          fleet_detail: fleet,
          fleet_detail_squads: squads,
          toast: {:success, "Agent removed from squad"}
        )}

      {:error, reason} ->
        Process.send_after(self(), :clear_toast, 4_000)
        {:noreply, assign(socket, toast: {:error, "Failed: #{reason}"})}
    end
  end

  # Move agent to different fleet
  def handle_event("move_agent_to_fleet", %{"agent-id" => agent_id, "fleet-id" => fleet_id}, socket) do
    case Hub.Fleets.assign_agent_to_fleet(agent_id, fleet_id) do
      {:ok, _agent} ->
        # Reload everything
        tenant_fleets = Hub.Fleets.list_fleets(socket.assigns.tenant_id)
        socket = assign(socket, tenant_fleets: tenant_fleets)

        socket = if socket.assigns.selected_fleet_id do
          case Hub.Fleets.get_fleet(socket.assigns.selected_fleet_id) do
            {:ok, fleet, squads} ->
              assign(socket, fleet_detail: fleet, fleet_detail_squads: squads)
            _ -> socket
          end
        else
          socket
        end

        Process.send_after(self(), :clear_toast, 4_000)
        {:noreply, assign(socket, toast: {:success, "Agent moved to fleet"})}

      {:error, reason} ->
        Process.send_after(self(), :clear_toast, 4_000)
        {:noreply, assign(socket, toast: {:error, "Failed: #{reason}"})}
    end
  end

  # ══════════════════════════════════════════════════════════
  # Squad Management View Events
  # ══════════════════════════════════════════════════════════

  def handle_event("select_squad", %{"id" => id}, socket) do
    squad = Enum.find(socket.assigns.squads, &(&1.id == id))
    if squad do
      members = Hub.Fleets.squad_agents(id)
      memory = load_squad_memory(id)
      activity = filter_squad_activity(socket.assigns.activities, members)
      {:noreply, assign(socket,
        selected_squad: squad,
        selected_squad_members: members,
        selected_squad_memory: memory,
        selected_squad_activity: activity,
        squad_detail_tab: "members"
      )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close_squad_detail", _, socket) do
    {:noreply, assign(socket, selected_squad: nil, selected_squad_members: [], selected_squad_memory: [], selected_squad_activity: [])}
  end

  def handle_event("squad_detail_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, squad_detail_tab: tab)}
  end

  # Squad CRUD
  def handle_event("open_squad_create", _, socket) do
    {:noreply, assign(socket, squad_create_form_open: true, squad_view_form_name: "", squad_view_form_description: "", squad_view_form_capabilities: [], squad_capability_input: "")}
  end

  def handle_event("close_squad_create", _, socket) do
    {:noreply, assign(socket, squad_create_form_open: false)}
  end

  def handle_event("squad_create_name", %{"value" => v}, socket) do
    {:noreply, assign(socket, squad_view_form_name: v)}
  end

  def handle_event("squad_create_description", %{"value" => v}, socket) do
    {:noreply, assign(socket, squad_view_form_description: v)}
  end

  def handle_event("squad_capability_input", %{"value" => v}, socket) do
    {:noreply, assign(socket, squad_capability_input: v)}
  end

  def handle_event("add_squad_capability", _, socket) do
    cap = String.trim(socket.assigns.squad_capability_input)
    if cap != "" and cap not in socket.assigns.squad_view_form_capabilities do
      {:noreply, assign(socket, squad_view_form_capabilities: socket.assigns.squad_view_form_capabilities ++ [cap], squad_capability_input: "")}
    else
      {:noreply, assign(socket, squad_capability_input: "")}
    end
  end

  def handle_event("remove_squad_capability", %{"cap" => cap}, socket) do
    {:noreply, assign(socket, squad_view_form_capabilities: Enum.reject(socket.assigns.squad_view_form_capabilities, &(&1 == cap)))}
  end

  def handle_event("save_new_squad", _, socket) do
    name = String.trim(socket.assigns.squad_view_form_name)
    fleet_id = socket.assigns.fleet_id

    if name == "" do
      Process.send_after(self(), :clear_toast, 4_000)
      {:noreply, assign(socket, toast: {:error, "Squad name cannot be empty"})}
    else
      attrs = %{
        name: name,
        capabilities: socket.assigns.squad_view_form_capabilities
      }
      attrs = if socket.assigns.squad_view_form_description != "" do
        Map.put(attrs, :settings, %{"description" => socket.assigns.squad_view_form_description})
      else
        attrs
      end

      case Hub.Fleets.create_squad(fleet_id, attrs) do
        {:ok, _squad} ->
          squads = load_squads_for_fleet(fleet_id)
          Process.send_after(self(), :clear_toast, 4_000)
          {:noreply, assign(socket,
            squads: squads,
            squad_create_form_open: false,
            toast: {:success, "Squad \"#{name}\" created"}
          )}

        {:error, changeset} when is_struct(changeset) ->
          error = Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
                  |> Enum.map_join(". ", fn {field, msgs} -> "#{field}: #{Enum.join(msgs, ", ")}" end)
          Process.send_after(self(), :clear_toast, 4_000)
          {:noreply, assign(socket, toast: {:error, error})}

        {:error, reason} ->
          Process.send_after(self(), :clear_toast, 4_000)
          {:noreply, assign(socket, toast: {:error, "Failed: #{inspect(reason)}"})}
      end
    end
  end

  def handle_event("update_squad_name", %{"value" => name}, socket) do
    name = String.trim(name)
    squad = socket.assigns.selected_squad
    if squad && name != "" && name != squad.name do
      case Hub.Groups.update_group(squad.group_id, %{name: name}) do
        {:ok, updated} ->
          squads = load_squads_for_fleet(socket.assigns.fleet_id)
          updated = Enum.find(squads, &(&1.id == squad.id)) || updated
          Process.send_after(self(), :clear_toast, 4_000)
          {:noreply, assign(socket, selected_squad: updated, squads: squads, toast: {:success, "Squad name updated"})}
        {:error, _} ->
          Process.send_after(self(), :clear_toast, 4_000)
          {:noreply, assign(socket, toast: {:error, "Failed to update name"})}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("update_squad_description", %{"value" => desc}, socket) do
    squad = socket.assigns.selected_squad
    if squad do
      settings = Map.merge(squad.settings || %{}, %{"description" => String.trim(desc)})
      case Hub.Groups.update_group(squad.group_id, %{settings: settings}) do
        {:ok, updated} ->
          squads = load_squads_for_fleet(socket.assigns.fleet_id)
          updated = Enum.find(squads, &(&1.id == squad.id)) || updated
          {:noreply, assign(socket, selected_squad: updated, squads: squads)}
        {:error, _} ->
          Process.send_after(self(), :clear_toast, 4_000)
          {:noreply, assign(socket, toast: {:error, "Failed to update description"})}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("add_squad_detail_capability", %{"value" => cap_input}, socket) do
    cap = String.trim(cap_input)
    squad = socket.assigns.selected_squad
    if squad && cap != "" && cap not in (squad.capabilities || []) do
      new_caps = (squad.capabilities || []) ++ [cap]
      case Hub.Groups.update_group(squad.group_id, %{capabilities: new_caps}) do
        {:ok, updated} ->
          squads = load_squads_for_fleet(socket.assigns.fleet_id)
          updated = Enum.find(squads, &(&1.id == squad.id)) || updated
          {:noreply, assign(socket, selected_squad: updated, squads: squads)}
        {:error, _} ->
          Process.send_after(self(), :clear_toast, 4_000)
          {:noreply, assign(socket, toast: {:error, "Failed to add capability"})}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("remove_squad_detail_capability", %{"cap" => cap}, socket) do
    squad = socket.assigns.selected_squad
    if squad do
      new_caps = Enum.reject(squad.capabilities || [], &(&1 == cap))
      case Hub.Groups.update_group(squad.group_id, %{capabilities: new_caps}) do
        {:ok, updated} ->
          squads = load_squads_for_fleet(socket.assigns.fleet_id)
          updated = Enum.find(squads, &(&1.id == squad.id)) || updated
          {:noreply, assign(socket, selected_squad: updated, squads: squads)}
        {:error, _} ->
          Process.send_after(self(), :clear_toast, 4_000)
          {:noreply, assign(socket, toast: {:error, "Failed to remove capability"})}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("delete_squad", %{"id" => id}, socket) do
    squad = Enum.find(socket.assigns.squads, &(&1.id == id))
    if squad do
      # Remove all agents from this squad first
      members = Hub.Fleets.squad_agents(id)
      Enum.each(members, fn agent ->
        Hub.Fleets.remove_agent_from_squad(agent.agent_id)
      end)
      # Dissolve the group
      Hub.Groups.dissolve_group(squad.group_id)
      squads = load_squads_for_fleet(socket.assigns.fleet_id)
      Process.send_after(self(), :clear_toast, 4_000)
      {:noreply, assign(socket,
        squads: squads,
        selected_squad: nil,
        selected_squad_members: [],
        selected_squad_memory: [],
        selected_squad_activity: [],
        toast: {:success, "Squad \"#{squad.name}\" deleted"}
      )}
    else
      {:noreply, socket}
    end
  end

  # Members
  def handle_event("squad_add_member", params, socket) do
    agent_id = Map.get(params, "agent-id") || Map.get(params, "value")
    squad = socket.assigns.selected_squad
    if squad && is_binary(agent_id) && agent_id != "" do
      case Hub.Fleets.assign_agent_to_squad(agent_id, squad.id) do
        {:ok, _} ->
          members = Hub.Fleets.squad_agents(squad.id)
          squads = load_squads_for_fleet(socket.assigns.fleet_id)
          squad_updated = Enum.find(squads, &(&1.id == squad.id))
          Process.send_after(self(), :clear_toast, 4_000)
          {:noreply, assign(socket, selected_squad_members: members, squads: squads, selected_squad: squad_updated || squad, toast: {:success, "Agent added to squad"})}

        {:error, reason} ->
          Process.send_after(self(), :clear_toast, 4_000)
          {:noreply, assign(socket, toast: {:error, "Failed: #{inspect(reason)}"})}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("squad_remove_member", %{"agent-id" => agent_id}, socket) do
    squad = socket.assigns.selected_squad
    if squad do
      case Hub.Fleets.remove_agent_from_squad(agent_id) do
        {:ok, _} ->
          members = Hub.Fleets.squad_agents(squad.id)
          squads = load_squads_for_fleet(socket.assigns.fleet_id)
          squad_updated = Enum.find(squads, &(&1.id == squad.id))
          Process.send_after(self(), :clear_toast, 4_000)
          {:noreply, assign(socket, selected_squad_members: members, squads: squads, selected_squad: squad_updated || squad, toast: {:success, "Agent removed from squad"})}

        {:error, reason} ->
          Process.send_after(self(), :clear_toast, 4_000)
          {:noreply, assign(socket, toast: {:error, "Failed: #{inspect(reason)}"})}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("squad_set_leader", params, socket) do
    agent_id = Map.get(params, "agent-id") || Map.get(params, "value")
    agent_id = if is_binary(agent_id) && agent_id != "", do: agent_id, else: nil
    squad = socket.assigns.selected_squad
    if squad && agent_id do
      # Find squad-leader role template, then assign to agent
      leader_role = try do
        case Hub.Roles.get_role_by_slug("squad-leader", socket.assigns.tenant_id) do
          {:ok, role} -> role
          _ -> nil
        end
      rescue
        _ -> nil
      end

      agent = Hub.Repo.get_by(Hub.Auth.Agent, agent_id: agent_id)
      if agent && leader_role do
        case Hub.Auth.Agent.changeset(agent, %{role_template_id: leader_role.id}) |> Hub.Repo.update() do
          {:ok, _} ->
            members = Hub.Fleets.squad_agents(squad.id)
            Process.send_after(self(), :clear_toast, 4_000)
            {:noreply, assign(socket, selected_squad_members: members, toast: {:success, "Squad leader set"})}
          {:error, _} ->
            Process.send_after(self(), :clear_toast, 4_000)
            {:noreply, assign(socket, toast: {:error, "Failed to set leader"})}
        end
      else
        # Store leader in squad settings metadata as fallback
        settings = Map.merge(squad.settings || %{}, %{"leader_agent_id" => agent_id})
        case Hub.Groups.update_group(squad.group_id, %{settings: settings}) do
          {:ok, updated} ->
            squads = load_squads_for_fleet(socket.assigns.fleet_id)
            updated = Enum.find(squads, &(&1.id == squad.id)) || updated
            members = Hub.Fleets.squad_agents(squad.id)
            Process.send_after(self(), :clear_toast, 4_000)
            {:noreply, assign(socket, selected_squad: updated, squads: squads, selected_squad_members: members, toast: {:success, "Squad leader set"})}
          {:error, _} ->
            Process.send_after(self(), :clear_toast, 4_000)
            {:noreply, assign(socket, toast: {:error, "Failed to set leader"})}
        end
      end
    else
      {:noreply, socket}
    end
  end

  # Memory
  def handle_event("squad_memory_search", %{"value" => filter}, socket) do
    squad = socket.assigns.selected_squad
    if squad do
      memory = load_squad_memory(squad.id)
      filtered = if filter == "" do
        memory
      else
        f = String.downcase(filter)
        Enum.filter(memory, fn entry ->
          String.contains?(String.downcase(entry["key"] || ""), f) ||
          String.contains?(String.downcase(entry["value"] || ""), f)
        end)
      end
      {:noreply, assign(socket, squad_memory_filter: filter, selected_squad_memory: filtered)}
    else
      {:noreply, assign(socket, squad_memory_filter: filter)}
    end
  end

  def handle_event("squad_memory_delete", %{"key" => key}, socket) do
    squad = socket.assigns.selected_squad
    if squad do
      Hub.SquadMemory.delete(squad.id, key)
      memory = load_squad_memory(squad.id)
      Process.send_after(self(), :clear_toast, 4_000)
      {:noreply, assign(socket, selected_squad_memory: memory, toast: {:success, "Memory key deleted"})}
    else
      {:noreply, socket}
    end
  end

  # Filter / Search / Sort
  def handle_event("set_filter", %{"filter" => f}, socket), do: {:noreply, assign(socket, filter: f)}
  def handle_event("update_search", %{"value" => v}, socket), do: {:noreply, assign(socket, search_query: v)}
  def handle_event("set_theme", %{"theme" => theme}, socket) when theme in ["light", "dark", "system"] do
    {:noreply, push_event(assign(socket, theme: theme), "set-theme", %{theme: theme})}
  end
  def handle_event("sort_agents", %{"column" => col}, socket) do
    col = String.to_existing_atom(col)
    dir = if socket.assigns.sort_by == col && socket.assigns.sort_dir == :asc, do: :desc, else: :asc
    {:noreply, assign(socket, sort_by: col, sort_dir: dir)}
  end

  def handle_event("clear_toast", _, socket), do: {:noreply, assign(socket, toast: nil)}

  # ── ESC key handler ────────────────────────────────────────

  def handle_event("esc_pressed", _, socket) do
    cond do
      socket.assigns[:wizard_open] ->
        {:noreply, assign(socket,
          wizard_open: false, wizard_step: 1, wizard_framework: nil,
          wizard_agent_name: "", wizard_live_key: nil, wizard_waiting: false,
          wizard_connected_agent: nil
        )}
      socket.assigns.cmd_open ->
        {:noreply, assign(socket, cmd_open: false, cmd_query: "")}
      socket.assigns[:kanban_detail_open] ->
        {:noreply, assign(socket, kanban_detail_open: false, kanban_selected_task: nil, kanban_edit_mode: false)}
      socket.assigns[:kanban_create_open] ->
        {:noreply, assign(socket, kanban_create_open: false)}
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

  # Generate a new key (without revoking existing ones)
  def handle_event("generate_key", %{"type" => type}, socket) when type in ["live", "test", "admin"] do
    tenant_id = socket.assigns.tenant_id
    fleet_id = socket.assigns.fleet_id

    case Hub.Auth.generate_api_key(type, tenant_id, fleet_id) do
      {:ok, raw_key, _api_key} ->
        Process.send_after(self(), :clear_toast, 8_000)
        {:noreply, assign(socket,
          toast: {:success, "New #{type} key generated"},
          new_api_key: raw_key,
          new_api_key_type: type,
          active_keys: load_active_keys(tenant_id)
        )}
      {:error, _} ->
        Process.send_after(self(), :clear_toast, 4_000)
        {:noreply, assign(socket, toast: {:error, "Failed to generate key"})}
    end
  end

  def handle_event("generate_key", _, socket) do
    {:noreply, assign(socket, toast: {:error, "Invalid key type"})}
  end

  # ── Add Agent Wizard ───────────────────────────────────────

  def handle_event("open_wizard", _, socket) do
    tenant_id = socket.assigns.tenant_id
    fleet_id = socket.assigns.fleet_id

    # Auto-generate a live key for the wizard
    live_key = case Hub.Auth.generate_api_key("live", tenant_id, fleet_id) do
      {:ok, raw_key, _api_key} -> raw_key
      _ -> "ERROR_GENERATING_KEY"
    end

    {:noreply, assign(socket,
      wizard_open: true,
      wizard_step: 1,
      wizard_framework: nil,
      wizard_agent_name: "",
      wizard_live_key: live_key,
      wizard_waiting: false,
      wizard_connected_agent: nil,
      wizard_agent_count_at_open: map_size(socket.assigns.agents),
      active_keys: load_active_keys(tenant_id)
    )}
  end

  def handle_event("close_wizard", _, socket) do
    {:noreply, assign(socket,
      wizard_open: false,
      wizard_step: 1,
      wizard_framework: nil,
      wizard_agent_name: "",
      wizard_live_key: nil,
      wizard_waiting: false,
      wizard_connected_agent: nil
    )}
  end

  def handle_event("wizard_select_framework", %{"framework" => framework}, socket) do
    {:noreply, assign(socket, wizard_framework: framework, wizard_step: 2)}
  end

  def handle_event("wizard_set_name", %{"value" => value}, socket) do
    {:noreply, assign(socket, wizard_agent_name: value)}
  end

  def handle_event("wizard_back", _, socket) do
    step = max(socket.assigns.wizard_step - 1, 1)
    {:noreply, assign(socket, wizard_step: step, wizard_waiting: false)}
  end

  def handle_event("wizard_next", _, socket) do
    step = min(socket.assigns.wizard_step + 1, 4)
    {:noreply, assign(socket, wizard_step: step)}
  end

  def handle_event("wizard_start_waiting", _, socket) do
    Process.send_after(self(), :wizard_check_agent, 2_000)
    {:noreply, assign(socket, wizard_waiting: true, wizard_step: 4)}
  end

  # Revoke a single key by ID
  def handle_event("revoke_key", %{"id" => key_id}, socket) do
    import Ecto.Query
    tenant_id = socket.assigns.tenant_id
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} = from(k in Hub.Auth.ApiKey,
      where: k.id == ^key_id and k.tenant_id == ^tenant_id and is_nil(k.revoked_at)
    ) |> Hub.Repo.update_all(set: [revoked_at: now])

    if count > 0 do
      Process.send_after(self(), :clear_toast, 4_000)
      {:noreply, assign(socket,
        toast: {:success, "Key revoked"},
        active_keys: load_active_keys(tenant_id)
      )}
    else
      {:noreply, assign(socket, toast: {:error, "Key not found"})}
    end
  end

  # ── Kanban Board Events ─────────────────────────────────────

  def handle_event("kanban_refresh", _, socket) do
    {:noreply, load_kanban_board(socket)}
  end

  def handle_event("kanban_open_create", _, socket) do
    {:noreply, assign(socket,
      kanban_create_open: true,
      kanban_form: %{
        title: "", description: "", priority: "medium", effort: "medium",
        assigned_to: "", squad_id: "", acceptance_criteria: [], new_criterion: ""
      }
    )}
  end

  def handle_event("kanban_close_create", _, socket) do
    {:noreply, assign(socket, kanban_create_open: false)}
  end

  def handle_event("kanban_form_field", %{"field" => field, "value" => value}, socket) do
    form = Map.put(socket.assigns.kanban_form, String.to_existing_atom(field), value)
    {:noreply, assign(socket, kanban_form: form)}
  end

  def handle_event("kanban_add_criterion", _, socket) do
    form = socket.assigns.kanban_form
    criterion = String.trim(form.new_criterion)
    if criterion != "" do
      form = %{form | acceptance_criteria: form.acceptance_criteria ++ [criterion], new_criterion: ""}
      {:noreply, assign(socket, kanban_form: form)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("kanban_remove_criterion", %{"index" => idx}, socket) do
    form = socket.assigns.kanban_form
    idx = String.to_integer(idx)
    criteria = List.delete_at(form.acceptance_criteria, idx)
    {:noreply, assign(socket, kanban_form: %{form | acceptance_criteria: criteria})}
  end

  def handle_event("kanban_save_task", _, socket) do
    form = socket.assigns.kanban_form
    title = String.trim(form.title)

    if title == "" do
      Process.send_after(self(), :clear_toast, 4_000)
      {:noreply, assign(socket, toast: {:error, "Task title is required"})}
    else
      attrs = %{
        title: title,
        description: form.description,
        priority: form.priority,
        effort: form.effort,
        tenant_id: socket.assigns.tenant_id,
        created_by: "dashboard",
        acceptance_criteria: form.acceptance_criteria
      }
      attrs = if form.assigned_to != "", do: Map.put(attrs, :assigned_to, form.assigned_to), else: attrs
      attrs = if form.squad_id != "", do: Map.put(attrs, :squad_id, form.squad_id), else: attrs

      case Hub.Kanban.create_task(socket.assigns.fleet_id, attrs) do
        {:ok, task} ->
          Process.send_after(self(), :clear_toast, 4_000)
          socket = assign(socket, kanban_create_open: false, toast: {:success, "Task #{task.task_id} created"})
          {:noreply, load_kanban_board(socket)}

        {:error, changeset} when is_struct(changeset) ->
          error = Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
                  |> Enum.map_join(". ", fn {field, msgs} -> "#{field}: #{Enum.join(msgs, ", ")}" end)
          Process.send_after(self(), :clear_toast, 4_000)
          {:noreply, assign(socket, toast: {:error, error})}

        {:error, reason} ->
          Process.send_after(self(), :clear_toast, 4_000)
          {:noreply, assign(socket, toast: {:error, "Failed: #{inspect(reason)}"})}
      end
    end
  end

  def handle_event("kanban_select_task", %{"task-id" => task_id}, socket) do
    case Hub.Kanban.get_task(task_id) do
      {:ok, task} ->
        history = case Hub.Kanban.task_history(task_id) do
          {:ok, h} -> h
          _ -> []
        end
        task_artifacts = Hub.Artifacts.task_artifacts(task.task_id)
        task_threads = Hub.Messaging.Threads.list_threads(socket.assigns.fleet_id, task_id: task.task_id)
        {:noreply, assign(socket,
          kanban_selected_task: task,
          kanban_detail_open: true,
          kanban_task_history: history,
          kanban_edit_mode: false,
          kanban_progress_pct: task.progress_pct || 0,
          selected_task_artifacts: task_artifacts,
          selected_task_threads: task_threads
        )}
      {:error, _} ->
        {:noreply, assign(socket, toast: {:error, "Task not found"})}
    end
  end

  def handle_event("kanban_close_detail", _, socket) do
    {:noreply, assign(socket, kanban_detail_open: false, kanban_selected_task: nil, kanban_edit_mode: false, selected_task_artifacts: [], selected_task_threads: [])}
  end

  def handle_event("kanban_move_task", %{"task-id" => task_id, "lane" => lane}, socket) do
    case Hub.Kanban.move_task(task_id, lane, "dashboard") do
      {:ok, _task} ->
        Process.send_after(self(), :clear_toast, 4_000)
        socket = assign(socket, toast: {:success, "Task moved to #{String.replace(lane, "_", " ")}"})
        # Reload task detail if still open
        socket = if socket.assigns.kanban_selected_task && socket.assigns.kanban_selected_task.task_id == task_id do
          case Hub.Kanban.get_task(task_id) do
            {:ok, task} ->
              history = case Hub.Kanban.task_history(task_id) do {:ok, h} -> h; _ -> [] end
              assign(socket, kanban_selected_task: task, kanban_task_history: history)
            _ -> socket
          end
        else
          socket
        end
        {:noreply, load_kanban_board(socket)}

      {:error, {:invalid_transition, from, to, valid}} ->
        Process.send_after(self(), :clear_toast, 4_000)
        {:noreply, assign(socket, toast: {:error, "Cannot move from #{from} to #{to}. Valid: #{Enum.join(valid, ", ")}"})}

      {:error, reason} ->
        Process.send_after(self(), :clear_toast, 4_000)
        {:noreply, assign(socket, toast: {:error, "Move failed: #{inspect(reason)}"})}
    end
  end

  def handle_event("kanban_update_progress", %{"value" => value}, socket) do
    pct = case Integer.parse(value) do
      {n, _} -> max(0, min(100, n))
      _ -> 0
    end
    {:noreply, assign(socket, kanban_progress_pct: pct)}
  end

  def handle_event("kanban_save_progress", _, socket) do
    task = socket.assigns.kanban_selected_task
    if task do
      case Hub.Kanban.update_task(task.task_id, %{progress_pct: socket.assigns.kanban_progress_pct}) do
        {:ok, updated} ->
          Process.send_after(self(), :clear_toast, 4_000)
          socket = assign(socket, kanban_selected_task: updated, toast: {:success, "Progress updated"})
          {:noreply, load_kanban_board(socket)}
        {:error, _} ->
          {:noreply, assign(socket, toast: {:error, "Failed to update progress"})}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("kanban_claim_task", %{"task-id" => task_id}, socket) do
    attrs = %{assigned_to: "dashboard"}
    case Hub.Kanban.update_task(task_id, attrs) do
      {:ok, task} ->
        Process.send_after(self(), :clear_toast, 4_000)
        socket = assign(socket, toast: {:success, "Claimed #{task.task_id}"})
        socket = if socket.assigns.kanban_selected_task && socket.assigns.kanban_selected_task.task_id == task_id do
          assign(socket, kanban_selected_task: task)
        else
          socket
        end
        {:noreply, load_kanban_board(socket)}
      {:error, _} ->
        {:noreply, assign(socket, toast: {:error, "Failed to claim task"})}
    end
  end

  def handle_event("kanban_filter", %{"field" => field, "value" => value}, socket) do
    value = if value == "", do: nil, else: value
    filters = Map.put(socket.assigns.kanban_filters, String.to_existing_atom(field), value)
    {:noreply, assign(socket, kanban_filters: filters) |> load_kanban_board()}
  end

  def handle_event("kanban_search", %{"value" => value}, socket) do
    filters = Map.put(socket.assigns.kanban_filters, :search, value)
    {:noreply, assign(socket, kanban_filters: filters) |> load_kanban_board()}
  end

  def handle_event("kanban_toggle_edit", _, socket) do
    {:noreply, assign(socket, kanban_edit_mode: !socket.assigns.kanban_edit_mode)}
  end

  def handle_event("kanban_update_field", %{"field" => field, "value" => value, "task-id" => task_id}, socket) do
    case Hub.Kanban.update_task(task_id, %{String.to_existing_atom(field) => value}) do
      {:ok, updated} ->
        Process.send_after(self(), :clear_toast, 4_000)
        socket = assign(socket, kanban_selected_task: updated, toast: {:success, "Updated"})
        {:noreply, load_kanban_board(socket)}
      {:error, _} ->
        {:noreply, assign(socket, toast: {:error, "Failed to update"})}
    end
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

  # ── Role Management Events ─────────────────────────────────

  def handle_event("select_role", %{"id" => id}, socket) do
    case Hub.Roles.get_role(id) do
      {:ok, role} ->
        {:noreply, assign(socket, selected_role: role, role_detail_open: true)}
      {:error, _} ->
        Process.send_after(self(), :clear_toast, 4_000)
        {:noreply, assign(socket, toast: {:error, "Role not found"})}
    end
  end

  def handle_event("close_role_detail", _, socket) do
    {:noreply, assign(socket, role_detail_open: false, selected_role: nil)}
  end

  def handle_event("open_role_form", %{"mode" => "create"}, socket) do
    {:noreply, assign(socket,
      role_form_open: true,
      role_form_mode: :create,
      role_form_id: nil,
      role_form: %{
        name: "", slug: "", system_prompt: "",
        capabilities: [], constraints: [], tools_allowed: [],
        escalation_rules: "", context_injection_tier: "auto",
        new_capability: "", new_constraint: "", new_tool: ""
      }
    )}
  end

  def handle_event("open_role_form", %{"mode" => "edit", "role-id" => role_id}, socket) do
    case Hub.Roles.get_role(role_id) do
      {:ok, role} ->
        {:noreply, assign(socket,
          role_form_open: true,
          role_form_mode: :edit,
          role_form_id: role_id,
          role_form: %{
            name: role.name || "",
            slug: role.slug || "",
            system_prompt: role.system_prompt || "",
            capabilities: role.capabilities || [],
            constraints: role.constraints || [],
            tools_allowed: role.tools_allowed || [],
            escalation_rules: role.escalation_rules || "",
            context_injection_tier: role.context_injection_tier || "auto",
            new_capability: "", new_constraint: "", new_tool: ""
          }
        )}
      {:error, _} ->
        Process.send_after(self(), :clear_toast, 4_000)
        {:noreply, assign(socket, toast: {:error, "Role not found"})}
    end
  end

  def handle_event("close_role_form", _, socket) do
    {:noreply, assign(socket, role_form_open: false)}
  end

  def handle_event("role_form_field", %{"field" => field, "value" => value}, socket) do
    form = socket.assigns.role_form
    form = case field do
      "name" ->
        slug = if socket.assigns.role_form_mode == :create do
          value |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")
        else
          form.slug
        end
        %{form | name: value, slug: slug}
      "slug" -> %{form | slug: value}
      "system_prompt" -> %{form | system_prompt: value}
      "escalation_rules" -> %{form | escalation_rules: value}
      "context_injection_tier" -> %{form | context_injection_tier: value}
      "new_capability" -> %{form | new_capability: value}
      "new_constraint" -> %{form | new_constraint: value}
      "new_tool" -> %{form | new_tool: value}
      _ -> form
    end
    {:noreply, assign(socket, role_form: form)}
  end

  # Handle select change for context_injection_tier (sent as %{"context_injection_tier" => val})
  def handle_event("role_form_field", %{"context_injection_tier" => value}, socket) do
    form = %{socket.assigns.role_form | context_injection_tier: value}
    {:noreply, assign(socket, role_form: form)}
  end

  # Handle select change for role_assign_agent (sent as %{"agent_id" => val})
  def handle_event("role_assign_agent_select", %{"agent_id" => agent_id}, socket) do
    {:noreply, assign(socket, role_assign_agent_id: agent_id)}
  end

  def handle_event("role_add_capability", _, socket) do
    form = socket.assigns.role_form
    cap = String.trim(form.new_capability)
    if cap != "" and cap not in form.capabilities do
      {:noreply, assign(socket, role_form: %{form | capabilities: form.capabilities ++ [cap], new_capability: ""})}
    else
      {:noreply, assign(socket, role_form: %{form | new_capability: ""})}
    end
  end

  def handle_event("role_remove_capability", %{"value" => cap}, socket) do
    form = socket.assigns.role_form
    {:noreply, assign(socket, role_form: %{form | capabilities: List.delete(form.capabilities, cap)})}
  end

  def handle_event("role_add_constraint", _, socket) do
    form = socket.assigns.role_form
    c = String.trim(form.new_constraint)
    if c != "" and c not in form.constraints do
      {:noreply, assign(socket, role_form: %{form | constraints: form.constraints ++ [c], new_constraint: ""})}
    else
      {:noreply, assign(socket, role_form: %{form | new_constraint: ""})}
    end
  end

  def handle_event("role_remove_constraint", %{"value" => c}, socket) do
    form = socket.assigns.role_form
    {:noreply, assign(socket, role_form: %{form | constraints: List.delete(form.constraints, c)})}
  end

  def handle_event("role_add_tool", _, socket) do
    form = socket.assigns.role_form
    t = String.trim(form.new_tool)
    if t != "" and t not in form.tools_allowed do
      {:noreply, assign(socket, role_form: %{form | tools_allowed: form.tools_allowed ++ [t], new_tool: ""})}
    else
      {:noreply, assign(socket, role_form: %{form | new_tool: ""})}
    end
  end

  def handle_event("role_remove_tool", %{"value" => t}, socket) do
    form = socket.assigns.role_form
    {:noreply, assign(socket, role_form: %{form | tools_allowed: List.delete(form.tools_allowed, t)})}
  end

  def handle_event("save_role", _, socket) do
    form = socket.assigns.role_form
    attrs = %{
      name: String.trim(form.name),
      slug: String.trim(form.slug),
      system_prompt: String.trim(form.system_prompt),
      capabilities: form.capabilities,
      constraints: form.constraints,
      tools_allowed: form.tools_allowed,
      escalation_rules: String.trim(form.escalation_rules),
      context_injection_tier: form.context_injection_tier
    }

    result = case socket.assigns.role_form_mode do
      :create -> Hub.Roles.create_role(socket.assigns.tenant_id, attrs)
      :edit -> Hub.Roles.update_role(socket.assigns.role_form_id, attrs)
    end

    case result do
      {:ok, _role} ->
        roles = Hub.Roles.list_roles(socket.assigns.tenant_id)
        action = if socket.assigns.role_form_mode == :create, do: "created", else: "updated"
        Process.send_after(self(), :clear_toast, 4_000)
        {:noreply, assign(socket,
          roles: roles,
          role_form_open: false,
          toast: {:success, "Role \"#{attrs.name}\" #{action}"}
        )}

      {:error, changeset} when is_struct(changeset) ->
        error = Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
                |> Enum.map_join(". ", fn {field, msgs} -> "#{field}: #{Enum.join(msgs, ", ")}" end)
        Process.send_after(self(), :clear_toast, 4_000)
        {:noreply, assign(socket, toast: {:error, error})}

      {:error, reason} ->
        Process.send_after(self(), :clear_toast, 4_000)
        {:noreply, assign(socket, toast: {:error, "Failed: #{reason}"})}
    end
  end

  def handle_event("delete_role", %{"id" => id}, socket) do
    case Hub.Roles.delete_role(id) do
      {:ok, _} ->
        roles = Hub.Roles.list_roles(socket.assigns.tenant_id)
        Process.send_after(self(), :clear_toast, 4_000)
        {:noreply, assign(socket,
          roles: roles,
          selected_role: nil,
          role_detail_open: false,
          toast: {:success, "Role deleted"}
        )}

      {:error, :predefined_immutable} ->
        Process.send_after(self(), :clear_toast, 4_000)
        {:noreply, assign(socket, toast: {:error, "Cannot delete predefined roles"})}

      {:error, _reason} ->
        Process.send_after(self(), :clear_toast, 4_000)
        {:noreply, assign(socket, toast: {:error, "Failed to delete role"})}
    end
  end

  def handle_event("assign_role", %{"agent-id" => agent_id, "role-id" => role_id}, socket) do
    case Hub.Roles.assign_role(agent_id, role_id) do
      {:ok, _} ->
        roles = Hub.Roles.list_roles(socket.assigns.tenant_id)
        Process.send_after(self(), :clear_toast, 4_000)
        {:noreply, assign(socket, roles: roles, toast: {:success, "Role assigned to agent"})}

      {:error, reason} ->
        Process.send_after(self(), :clear_toast, 4_000)
        {:noreply, assign(socket, toast: {:error, "Failed to assign role: #{reason}"})}
    end
  end

  def handle_event("unassign_role", %{"agent-id" => agent_id}, socket) do
    case Hub.Roles.unassign_role(agent_id) do
      {:ok, _} ->
        Process.send_after(self(), :clear_toast, 4_000)
        {:noreply, assign(socket, toast: {:success, "Role unassigned"})}

      {:error, reason} ->
        Process.send_after(self(), :clear_toast, 4_000)
        {:noreply, assign(socket, toast: {:error, "Failed: #{reason}"})}
    end
  end

  def handle_event("role_assign_to_agent", _, socket) do
    agent_id = socket.assigns.role_assign_agent_id
    role = socket.assigns.selected_role
    if agent_id && agent_id != "" && role do
      case Hub.Roles.assign_role(agent_id, role.id) do
        {:ok, _} ->
          Process.send_after(self(), :clear_toast, 4_000)
          {:noreply, assign(socket, role_assign_agent_id: nil, toast: {:success, "Role \"#{role.name}\" assigned to #{agent_id}"})}
        {:error, reason} ->
          Process.send_after(self(), :clear_toast, 4_000)
          {:noreply, assign(socket, toast: {:error, "Failed: #{reason}"})}
      end
    else
      {:noreply, socket}
    end
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

  def handle_info(:wizard_check_agent, socket) do
    if socket.assigns[:wizard_open] && socket.assigns[:wizard_waiting] && is_nil(socket.assigns[:wizard_connected_agent]) do
      current_count = map_size(socket.assigns.agents)
      if current_count > socket.assigns.wizard_agent_count_at_open do
        # Find the newest agent (one that wasn't there before)
        # Just pick the last one that joined
        {newest_id, newest_meta} = Enum.max_by(socket.assigns.agents, fn {_id, m} ->
          m[:connected_at] || ""
        end)
        {:noreply, assign(socket,
          wizard_connected_agent: %{id: newest_id, name: newest_meta[:name] || newest_id},
          wizard_step: 4,
          wizard_waiting: false
        )}
      else
        Process.send_after(self(), :wizard_check_agent, 2_000)
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  # Kanban PubSub real-time handlers
  def handle_info(%Phoenix.Socket.Broadcast{event: "kanban:task_created"}, socket) do
    {:noreply, maybe_reload_kanban(socket)}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "kanban:task_moved"}, socket) do
    {:noreply, maybe_reload_kanban(socket)}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "kanban:task_claimed"}, socket) do
    {:noreply, maybe_reload_kanban(socket)}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "kanban:task_updated"}, socket) do
    {:noreply, maybe_reload_kanban(socket)}
  end

  def handle_info({:kanban_event, _event}, socket) do
    {:noreply, maybe_reload_kanban(socket)}
  end

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
              <div class="space-y-4 animate-fade-in">
                <%!-- Social login buttons --%>
                <div class="grid grid-cols-2 gap-3">
                  <a href="/auth/github" class="flex items-center justify-center gap-2 h-10 rounded-lg border border-zinc-700 bg-zinc-800 hover:bg-zinc-700 text-zinc-200 text-sm font-medium transition-colors">
                    <Icons.github class="w-4 h-4" />
                    GitHub
                  </a>
                  <a href="/auth/google" class="flex items-center justify-center gap-2 h-10 rounded-lg border border-zinc-700 bg-zinc-800 hover:bg-zinc-700 text-zinc-200 text-sm font-medium transition-colors">
                    <Icons.google class="w-4 h-4" />
                    Google
                  </a>
                </div>

                <div class="relative">
                  <.separator />
                  <span class="absolute left-1/2 top-1/2 -translate-x-1/2 -translate-y-1/2 bg-zinc-900 px-3 text-xs text-zinc-500">or</span>
                </div>

                <%!-- Email + Password --%>
                <form action="/auth/login" method="post" class="space-y-4">
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

                <%!-- Magic link divider --%>
                <div class="relative">
                  <.separator />
                  <span class="absolute left-1/2 top-1/2 -translate-x-1/2 -translate-y-1/2 bg-zinc-900 px-3 text-xs text-zinc-500">or</span>
                </div>

                <%!-- Magic link --%>
                <form action="/auth/magic-link" method="post" class="space-y-3">
                  <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
                  <div>
                    <label class="text-xs text-zinc-400 mb-1.5 block font-medium">Sign in with magic link</label>
                    <.input
                      type="email"
                      name="email"
                      value={@magic_link_email}
                      placeholder="you@example.com"
                      autocomplete="email"
                      required
                      class="w-full bg-zinc-950 border-zinc-700 text-zinc-100 placeholder:text-zinc-600 focus:border-amber-500/50"
                    />
                  </div>
                  <.button
                    type="submit"
                    variant="outline"
                    class="w-full border-zinc-700 text-zinc-300 hover:bg-zinc-800 font-semibold h-10"
                  >
                    <Icons.mail class="w-4 h-4 mr-2" />
                    Send Magic Link
                  </.button>
                </form>
              </div>
            <% end %>

            <%!-- Register tab --%>
            <%= if @auth_tab == "register" do %>
              <div class="space-y-4 animate-fade-in">
                <%!-- Social register buttons --%>
                <div class="grid grid-cols-2 gap-3">
                  <a href="/auth/github" class="flex items-center justify-center gap-2 h-10 rounded-lg border border-zinc-700 bg-zinc-800 hover:bg-zinc-700 text-zinc-200 text-sm font-medium transition-colors">
                    <Icons.github class="w-4 h-4" />
                    GitHub
                  </a>
                  <a href="/auth/google" class="flex items-center justify-center gap-2 h-10 rounded-lg border border-zinc-700 bg-zinc-800 hover:bg-zinc-700 text-zinc-200 text-sm font-medium transition-colors">
                    <Icons.google class="w-4 h-4" />
                    Google
                  </a>
                </div>

                <div class="relative">
                  <.separator />
                  <span class="absolute left-1/2 top-1/2 -translate-x-1/2 -translate-y-1/2 bg-zinc-900 px-3 text-xs text-zinc-500">or</span>
                </div>

                <form action="/auth/register" method="post" class="space-y-4">
                  <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
                  <%= if @invite_only do %>
                    <div>
                      <label class="text-xs text-zinc-400 mb-1.5 block font-medium">
                        Invite Code
                        <span class="text-amber-400">*</span>
                      </label>
                      <.input
                        type="text"
                        name="invite_code"
                        value={@invite_code}
                        placeholder="Enter invite code"
                        required
                        autocomplete="off"
                        class="w-full bg-zinc-950 border-zinc-700 text-zinc-100 placeholder:text-zinc-600 focus:border-amber-500/50 font-mono"
                      />
                    </div>
                  <% end %>
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
                    Free plan · 10 agents · No credit card required
                    <%= if @invite_only do %>
                      <br/><span class="text-amber-400/70">Invite code required</span>
                    <% end %>
                  </p>
                </form>
              </div>
            <% end %>

            <%!-- API Key tab --%>
            <%= if @auth_tab == "apikey" do %>
              <form action="/auth/api-key" method="post" class="space-y-4 animate-fade-in">
                <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
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
                  Key is submitted securely — never stored in URL
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

      <%!-- Add Agent Wizard --%>
      <%= if @wizard_open do %>
        <%= render_add_agent_wizard(assigns) %>
      <% end %>

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
            <%!-- OPERATIONS --%>
            <div class="text-[10px] font-semibold text-zinc-500 uppercase tracking-wider px-3 py-2">Operations</div>
            <Components.nav_item view="dashboard" icon={:layout_dashboard} label="Dashboard" active={@current_view == "dashboard"} />
            <Components.nav_item view="agents" icon={:bot} label="Agents" active={@current_view == "agents"} badge={to_string(map_size(@agents))} />
            <Components.nav_item view="kanban" icon={:kanban} label="Kanban" active={@current_view == "kanban"} />
            <Components.nav_item view="messaging" icon={:message_square} label="Messaging" active={@current_view == "messaging"} />

            <%!-- ORGANIZATION --%>
            <div class="text-[10px] font-semibold text-zinc-500 uppercase tracking-wider px-3 py-2 mt-4">Organization</div>
            <Components.nav_item view="fleets" icon={:layers} label="Fleets" active={@current_view == "fleets"} badge={to_string(length(@tenant_fleets))} />
            <Components.nav_item view="squads" icon={:users} label="Squads" active={@current_view == "squads"} badge={to_string(length(@squads))} />
            <Components.nav_item view="roles" icon={:shield} label="Roles" active={@current_view == "roles"} />
            <Components.nav_item view="activity" icon={:activity} label="Activity" active={@current_view == "activity"} />

            <%!-- INFRASTRUCTURE --%>
            <div class="text-[10px] font-semibold text-zinc-500 uppercase tracking-wider px-3 py-2 mt-4">Infrastructure</div>
            <Components.nav_link href="/webhooks" icon={:webhook} label="Webhooks" />
            <Components.nav_link href="/devices" icon={:smartphone} label="Devices" />
            <Components.nav_link href="/dashboard/metrics" icon={:bar_chart} label="Metrics" />

            <%!-- ADMIN --%>
            <div class="text-[10px] font-semibold text-zinc-500 uppercase tracking-wider px-3 py-2 mt-4">Admin</div>
            <Components.nav_item view="quotas" icon={:gauge} label="Quotas" active={@current_view == "quotas"} />
            <Components.nav_link href="/billing" icon={:credit_card} label="Billing" />
            <Components.nav_link href="/invites" icon={:user_plus} label="Invites" />
            <Components.nav_link href="/audit" icon={:file_search} label="Audit" />
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
            <% "fleets" -> %> <%= render_fleets(assigns) %>
            <% "squads" -> %> <%= render_squads(assigns) %>
            <% "agents" -> %> <%= render_agents(assigns) %>
            <% "roles" -> %> <%= render_roles(assigns) %>
            <% "activity" -> %> <%= render_activity(assigns) %>
            <% "kanban" -> %> <%= render_kanban(assigns) %>
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

    # Kanban-integrated stats
    fleet_id = assigns.fleet_id
    kanban_stats = try do Hub.Kanban.board_stats(fleet_id) rescue _ -> %{} end
    lane_counts = kanban_stats["lanes"] || %{}
    active_tasks = lane_counts["in_progress"] || 0
    review_lane_count = lane_counts["review"] || 0
    pending_artifacts = try do
      Hub.Artifacts.list_artifacts(fleet_id, %{status: "pending_review"}) |> length()
    rescue _ -> 0
    end
    pending_review = review_lane_count + pending_artifacts
    velocity_day = kanban_stats["velocity_24h"] || 0
    escalation_count = try do
      # Count all pending escalations by listing for a sentinel — use all_escalations approach
      Hub.Messaging.Escalation.list_pending(fleet_id, "dashboard") |> length()
    rescue _ -> 0
    end

    # Role distribution
    role_dist = try do
      roles = Hub.Roles.list_roles(assigns.tenant_id)
      role_map = Enum.into(roles, %{}, fn r -> {r.id, r.name} end)
      # Count agents by role — query Agent schema directly
      import Ecto.Query, only: [from: 2]
      agent_list = Hub.Repo.all(from a in Hub.Auth.Agent, where: a.fleet_id == ^fleet_id)
      Enum.reduce(agent_list, %{}, fn agent, acc ->
        role_name = if agent.role_template_id, do: Map.get(role_map, agent.role_template_id, "Unknown"), else: "No Role"
        Map.update(acc, role_name, 1, &(&1 + 1))
      end)
    rescue _ -> %{}
    end

    assigns = assign(assigns,
      agents_sorted: agents_sorted, recent: recent,
      ov_online: online, msg_info: msg_info, mem_info: mem_info,
      ov_active_tasks: active_tasks, ov_pending_review: pending_review,
      ov_velocity_day: velocity_day, ov_escalation_count: escalation_count,
      ov_lane_counts: lane_counts, ov_role_dist: role_dist
    )

    ~H"""
    <div class="h-full overflow-y-auto p-6 space-y-6 animate-fade-in">
      <div>
        <h2 class="text-lg font-semibold text-zinc-100">Dashboard</h2>
        <p class="text-sm text-zinc-500">Fleet overview and real-time status</p>
      </div>

      <%!-- Stat cards --%>
      <div class="grid grid-cols-2 lg:grid-cols-6 gap-3">
        <Components.stat_card label="Total Agents" value={to_string(map_size(@agents))} icon={:bot} color="amber" />
        <Components.stat_card label="Online Now" value={to_string(@ov_online)} icon={:wifi} color="green" delta={"+" <> to_string(@ov_online)} delta_type={:positive} />
        <Components.stat_card label="Active Tasks" value={to_string(@ov_active_tasks)} icon={:layers} color="blue" />
        <Components.stat_card label="Pending Review" value={to_string(@ov_pending_review)} icon={:message_square} color="yellow" />
        <Components.stat_card label="Velocity/day" value={to_string(@ov_velocity_day)} icon={:layers} color="emerald" />
        <Components.stat_card label="Escalations" value={to_string(@ov_escalation_count)} icon={:brain} color={if @ov_escalation_count > 0, do: "red", else: "purple"} />
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-[1fr_360px] gap-6 lg-grid-sidebar">
        <%!-- Agent grid --%>
        <div>
          <div class="flex items-center justify-between mb-3">
            <h3 class="text-sm font-medium text-zinc-300">Active Agents</h3>
            <div class="flex items-center gap-2">
              <.button variant="outline" size="sm" phx-click="open_wizard" class="text-[10px] h-7 px-2.5 border-amber-500/30 text-amber-400 hover:bg-amber-500/10 hover:text-amber-300">
                <Icons.plus class="w-3 h-3 mr-1" /> Add Agent
              </.button>
              <.button variant="link" phx-click="navigate" phx-value-view="agents" class="text-xs text-amber-400 hover:text-amber-300 p-0 h-auto">View all →</.button>
            </div>
          </div>
          <%= if map_size(@agents) == 0 do %>
            <div class="space-y-3">
              <Components.empty_state message="No agents connected" subtitle="Agents appear here when they join the fleet" icon={:bot} />
              <div class="text-center">
                <.button variant="outline" phx-click="open_wizard" class="border-amber-500/30 text-amber-400 hover:bg-amber-500/10 hover:text-amber-300">
                  <Icons.plus class="w-4 h-4 mr-2" /> Add Your First Agent
                </.button>
              </div>
            </div>
          <% else %>
            <div class="grid grid-cols-2 xl:grid-cols-3 gap-2">
              <%= for {agent_id, meta} <- @agents_sorted do %>
                <Components.agent_grid_card agent_id={agent_id} meta={meta} />
              <% end %>
            </div>
          <% end %>

          <%!-- Kanban mini-summary --%>
          <div class="mt-4">
            <div class="flex items-center justify-between mb-2">
              <h3 class="text-sm font-medium text-zinc-300">Kanban Summary</h3>
              <.button variant="link" phx-click="navigate" phx-value-view="kanban" class="text-xs text-amber-400 hover:text-amber-300 p-0 h-auto">Board →</.button>
            </div>
            <.card class="bg-zinc-900 border-zinc-800">
              <.card_content class="p-3">
                <div class="flex items-center gap-2 flex-wrap text-xs">
                  <button phx-click="navigate" phx-value-view="kanban" class="flex items-center gap-1 px-2 py-1 rounded-md bg-zinc-800/50 hover:bg-zinc-800 transition-colors text-zinc-400 hover:text-zinc-200">
                    <span>📋</span>
                    <span>Backlog: <span class="font-medium text-zinc-200"><%= @ov_lane_counts["backlog"] || 0 %></span></span>
                  </button>
                  <span class="text-zinc-700">|</span>
                  <button phx-click="navigate" phx-value-view="kanban" class="flex items-center gap-1 px-2 py-1 rounded-md bg-zinc-800/50 hover:bg-zinc-800 transition-colors text-zinc-400 hover:text-zinc-200">
                    <span>🟢</span>
                    <span>Ready: <span class="font-medium text-green-400"><%= @ov_lane_counts["ready"] || 0 %></span></span>
                  </button>
                  <span class="text-zinc-700">|</span>
                  <button phx-click="navigate" phx-value-view="kanban" class="flex items-center gap-1 px-2 py-1 rounded-md bg-zinc-800/50 hover:bg-zinc-800 transition-colors text-zinc-400 hover:text-zinc-200">
                    <span>🔵</span>
                    <span>Active: <span class="font-medium text-blue-400"><%= @ov_lane_counts["in_progress"] || 0 %></span></span>
                  </button>
                  <span class="text-zinc-700">|</span>
                  <button phx-click="navigate" phx-value-view="kanban" class="flex items-center gap-1 px-2 py-1 rounded-md bg-zinc-800/50 hover:bg-zinc-800 transition-colors text-zinc-400 hover:text-zinc-200">
                    <span>🟡</span>
                    <span>Review: <span class="font-medium text-yellow-400"><%= @ov_lane_counts["review"] || 0 %></span></span>
                  </button>
                  <span class="text-zinc-700">|</span>
                  <button phx-click="navigate" phx-value-view="kanban" class="flex items-center gap-1 px-2 py-1 rounded-md bg-zinc-800/50 hover:bg-zinc-800 transition-colors text-zinc-400 hover:text-zinc-200">
                    <span>✅</span>
                    <span>Done: <span class="font-medium text-emerald-400"><%= @ov_lane_counts["done"] || 0 %></span></span>
                  </button>
                </div>
              </.card_content>
            </.card>
          </div>

          <%!-- Role Distribution --%>
          <%= if @ov_role_dist != %{} do %>
            <div class="mt-4">
              <h3 class="text-sm font-medium text-zinc-300 mb-2">Role Distribution</h3>
              <.card class="bg-zinc-900 border-zinc-800">
                <.card_content class="p-3">
                  <div class="flex items-center gap-2 flex-wrap text-xs text-zinc-400">
                    <%= for {role_name, count} <- Enum.sort_by(@ov_role_dist, fn {_, c} -> -c end) do %>
                      <span class="px-2 py-1 rounded-md bg-zinc-800/50">
                        <span class="text-zinc-200 font-medium"><%= role_name %></span>
                        <span class="text-zinc-500">(<%= count %>)</span>
                      </span>
                    <% end %>
                  </div>
                </.card_content>
              </.card>
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
  # Page: Fleets
  # ══════════════════════════════════════════════════════════

  defp render_fleets(assigns) do
    ~H"""
    <div class="h-full flex animate-fade-in">
      <%!-- Fleet list panel --%>
      <div class="w-72 border-r border-zinc-800 flex flex-col overflow-hidden shrink-0 bg-zinc-900">
        <div class="px-4 py-4 border-b border-zinc-800">
          <div class="flex items-center justify-between mb-1">
            <h2 class="text-sm font-semibold text-zinc-100">Fleets</h2>
            <.button variant="outline" size="sm" phx-click="open_fleet_form" phx-value-mode="create"
              class="h-7 px-2.5 text-[10px] border-amber-500/30 text-amber-400 hover:bg-amber-500/10">
              <Icons.plus class="w-3 h-3 mr-1" /> New Fleet
            </.button>
          </div>
          <p class="text-[11px] text-zinc-500"><%= length(@tenant_fleets) %> fleet<%= if length(@tenant_fleets) != 1, do: "s" %></p>
        </div>

        <div class="flex-1 overflow-y-auto p-2 space-y-1">
          <%= for fleet <- @tenant_fleets do %>
            <button
              phx-click="select_fleet"
              phx-value-fleet-id={fleet.id}
              class={"w-full text-left px-3 py-2.5 rounded-lg transition-colors duration-150 group " <>
                if(@selected_fleet_id == fleet.id, do: "bg-zinc-800 border border-zinc-700", else: "hover:bg-zinc-800/50 border border-transparent")}
            >
              <div class="flex items-center justify-between">
                <div class="min-w-0 flex-1">
                  <div class="text-sm font-medium text-zinc-200 truncate"><%= fleet.name %></div>
                  <%= if fleet.description && fleet.description != "" do %>
                    <div class="text-[10px] text-zinc-500 truncate mt-0.5"><%= fleet.description %></div>
                  <% end %>
                </div>
                <div class="flex items-center gap-2 ml-2 shrink-0">
                  <div class="flex items-center gap-1">
                    <Icons.bot class="w-3 h-3 text-zinc-600" />
                    <span class="text-[10px] text-zinc-500"><%= fleet.agent_count %></span>
                  </div>
                  <div class="flex items-center gap-1">
                    <Icons.users class="w-3 h-3 text-zinc-600" />
                    <span class="text-[10px] text-zinc-500"><%= fleet.squad_count %></span>
                  </div>
                </div>
              </div>
            </button>
          <% end %>

          <%= if @tenant_fleets == [] do %>
            <div class="text-center py-8">
              <Icons.layers class="w-8 h-8 text-zinc-700 mx-auto mb-2" />
              <p class="text-xs text-zinc-600">No fleets yet</p>
            </div>
          <% end %>
        </div>
      </div>

      <%!-- Fleet detail panel --%>
      <div class="flex-1 overflow-y-auto">
        <%= if @fleet_detail do %>
          <div class="p-6 space-y-6">
            <%!-- Fleet header --%>
            <div class="flex items-center justify-between">
              <div>
                <div class="flex items-center gap-3">
                  <div class="w-10 h-10 rounded-xl bg-amber-500/15 border border-amber-500/25 flex items-center justify-center">
                    <Icons.layers class="w-5 h-5 text-amber-400" />
                  </div>
                  <div>
                    <h2 class="text-lg font-semibold text-zinc-100"><%= @fleet_detail.name %></h2>
                    <%= if @fleet_detail.description && @fleet_detail.description != "" do %>
                      <p class="text-sm text-zinc-500"><%= @fleet_detail.description %></p>
                    <% end %>
                  </div>
                </div>
              </div>
              <div class="flex items-center gap-2">
                <.button variant="outline" size="sm"
                  phx-click="open_fleet_form"
                  phx-value-mode="edit"
                  phx-value-fleet-id={@fleet_detail.id}
                  class="h-8 text-xs border-zinc-700 text-zinc-400 hover:text-zinc-200">
                  <Icons.pencil class="w-3.5 h-3.5 mr-1.5" /> Edit
                </.button>
                <.button variant="outline" size="sm"
                  phx-click="delete_fleet"
                  phx-value-fleet-id={@fleet_detail.id}
                  data-confirm={"Delete fleet \"#{@fleet_detail.name}\"? This cannot be undone."}
                  class="h-8 text-xs border-red-500/20 text-red-400/70 hover:bg-red-500/10 hover:text-red-300">
                  <Icons.trash class="w-3.5 h-3.5 mr-1.5" /> Delete
                </.button>
              </div>
            </div>

            <%!-- Stats --%>
            <div class="grid grid-cols-3 gap-3">
              <.card class="bg-zinc-900 border-zinc-800">
                <.card_content class="p-3 text-center">
                  <div class="text-xl font-bold text-zinc-100"><%= length(@fleet_detail.agents) %></div>
                  <div class="text-[10px] text-zinc-500 mt-0.5">Agents</div>
                </.card_content>
              </.card>
              <.card class="bg-zinc-900 border-zinc-800">
                <.card_content class="p-3 text-center">
                  <div class="text-xl font-bold text-zinc-100"><%= length(@fleet_detail_squads) %></div>
                  <div class="text-[10px] text-zinc-500 mt-0.5">Squads</div>
                </.card_content>
              </.card>
              <.card class="bg-zinc-900 border-zinc-800">
                <.card_content class="p-3 text-center">
                  <% unassigned = Enum.count(@fleet_detail.agents, &is_nil(&1.squad_id)) %>
                  <div class="text-xl font-bold text-zinc-100"><%= unassigned %></div>
                  <div class="text-[10px] text-zinc-500 mt-0.5">Unassigned</div>
                </.card_content>
              </.card>
            </div>

            <%!-- Squads section --%>
            <div>
              <div class="flex items-center justify-between mb-3">
                <h3 class="text-sm font-medium text-zinc-300">Squads</h3>
                <.button variant="outline" size="sm"
                  phx-click="open_squad_form"
                  phx-value-fleet-id={@fleet_detail.id}
                  class="h-7 px-2.5 text-[10px] border-amber-500/30 text-amber-400 hover:bg-amber-500/10">
                  <Icons.plus class="w-3 h-3 mr-1" /> New Squad
                </.button>
              </div>

              <%= if @fleet_detail_squads == [] do %>
                <.card class="bg-zinc-900 border-zinc-800">
                  <.card_content class="p-6 text-center">
                    <Icons.users class="w-8 h-8 text-zinc-700 mx-auto mb-2" />
                    <p class="text-sm text-zinc-500">No squads yet</p>
                    <p class="text-[11px] text-zinc-600 mt-1">Create a squad to organize agents into teams</p>
                  </.card_content>
                </.card>
              <% else %>
                <div class="space-y-3">
                  <%= for squad <- @fleet_detail_squads do %>
                    <% squad_agents = Enum.filter(@fleet_detail.agents, &(&1.squad_id == squad.id)) %>
                    <.card class="bg-zinc-900 border-zinc-800">
                      <.card_content class="p-4">
                        <div class="flex items-center justify-between mb-3">
                          <div class="flex items-center gap-2">
                            <div class="w-7 h-7 rounded-lg bg-blue-500/15 flex items-center justify-center">
                              <Icons.users class="w-3.5 h-3.5 text-blue-400" />
                            </div>
                            <div>
                              <div class="text-sm font-medium text-zinc-200"><%= squad.name %></div>
                              <div class="text-[10px] text-zinc-500"><%= length(squad_agents) %> agent<%= if length(squad_agents) != 1, do: "s" %></div>
                            </div>
                          </div>
                          <%= if squad.capabilities != [] do %>
                            <div class="flex gap-1">
                              <%= for cap <- Enum.take(squad.capabilities, 3) do %>
                                <.badge variant="outline" class="text-[9px] px-1.5 py-0 bg-blue-500/10 text-blue-400 border-blue-500/15"><%= cap %></.badge>
                              <% end %>
                            </div>
                          <% end %>
                        </div>

                        <%= if squad_agents != [] do %>
                          <div class="space-y-1">
                            <%= for agent <- squad_agents do %>
                              <div class="flex items-center justify-between py-1.5 px-2 rounded-md bg-zinc-800/50 group">
                                <div class="flex items-center gap-2">
                                  <div class="w-5 h-5 rounded-md bg-zinc-700 flex items-center justify-center text-[9px] font-bold text-zinc-400">
                                    <%= String.first(agent.name || agent.agent_id) |> String.upcase() %>
                                  </div>
                                  <span class="text-xs text-zinc-300"><%= agent.name || agent.agent_id %></span>
                                  <span class="text-[10px] text-zinc-600 font-mono"><%= agent.agent_id %></span>
                                </div>
                                <button
                                  phx-click="remove_from_squad"
                                  phx-value-agent-id={agent.agent_id}
                                  class="text-[10px] text-zinc-600 hover:text-red-400 opacity-0 group-hover:opacity-100 transition-all"
                                  title="Remove from squad"
                                >
                                  <Icons.x class="w-3 h-3" />
                                </button>
                              </div>
                            <% end %>
                          </div>
                        <% else %>
                          <p class="text-[11px] text-zinc-600 italic">No agents in this squad</p>
                        <% end %>
                      </.card_content>
                    </.card>
                  <% end %>
                </div>
              <% end %>
            </div>

            <%!-- Unassigned agents --%>
            <div>
              <h3 class="text-sm font-medium text-zinc-300 mb-3">Agents in Fleet</h3>
              <% unassigned_agents = Enum.filter(@fleet_detail.agents, &is_nil(&1.squad_id)) %>
              <% assigned_agents = Enum.reject(@fleet_detail.agents, &is_nil(&1.squad_id)) %>

              <%= if @fleet_detail.agents == [] do %>
                <.card class="bg-zinc-900 border-zinc-800">
                  <.card_content class="p-6 text-center">
                    <Icons.bot class="w-8 h-8 text-zinc-700 mx-auto mb-2" />
                    <p class="text-sm text-zinc-500">No agents in this fleet</p>
                  </.card_content>
                </.card>
              <% else %>
                <%= if unassigned_agents != [] do %>
                  <div class="mb-3">
                    <div class="text-[10px] text-zinc-500 uppercase tracking-wider mb-2 font-medium">Unassigned (<%= length(unassigned_agents) %>)</div>
                    <div class="space-y-1">
                      <%= for agent <- unassigned_agents do %>
                        <div class="flex items-center justify-between py-2 px-3 rounded-lg bg-zinc-900 border border-zinc-800 group">
                          <div class="flex items-center gap-2.5">
                            <div class="w-6 h-6 rounded-lg bg-zinc-800 flex items-center justify-center text-[10px] font-bold text-zinc-400">
                              <%= String.first(agent.name || agent.agent_id) |> String.upcase() %>
                            </div>
                            <div>
                              <div class="text-xs font-medium text-zinc-200"><%= agent.name || agent.agent_id %></div>
                              <div class="text-[10px] text-zinc-600 font-mono"><%= agent.agent_id %></div>
                            </div>
                          </div>
                          <div class="flex items-center gap-1">
                            <%= if @fleet_detail_squads != [] do %>
                              <div class="relative">
                                <select
                                  phx-change="assign_to_squad"
                                  phx-value-agent-id={agent.agent_id}
                                  name={"squad-#{agent.agent_id}"}
                                  class="h-7 px-2 text-[10px] bg-zinc-800 border border-zinc-700 rounded text-zinc-400 focus:border-amber-500/50 focus:outline-none appearance-none pr-6 cursor-pointer opacity-0 group-hover:opacity-100 transition-opacity"
                                >
                                  <option value="">Assign to squad…</option>
                                  <%= for squad <- @fleet_detail_squads do %>
                                    <option value={squad.id}><%= squad.name %></option>
                                  <% end %>
                                </select>
                              </div>
                            <% end %>
                          </div>
                        </div>
                      <% end %>
                    </div>
                  </div>
                <% end %>

                <%= if assigned_agents != [] do %>
                  <div>
                    <div class="text-[10px] text-zinc-500 uppercase tracking-wider mb-2 font-medium">Assigned (<%= length(assigned_agents) %>)</div>
                    <div class="space-y-1">
                      <%= for agent <- assigned_agents do %>
                        <% squad = Enum.find(@fleet_detail_squads, &(&1.id == agent.squad_id)) %>
                        <div class="flex items-center justify-between py-2 px-3 rounded-lg bg-zinc-900 border border-zinc-800">
                          <div class="flex items-center gap-2.5">
                            <div class="w-6 h-6 rounded-lg bg-blue-500/15 flex items-center justify-center text-[10px] font-bold text-blue-400">
                              <%= String.first(agent.name || agent.agent_id) |> String.upcase() %>
                            </div>
                            <div>
                              <div class="text-xs font-medium text-zinc-200"><%= agent.name || agent.agent_id %></div>
                              <div class="text-[10px] text-zinc-600 font-mono"><%= agent.agent_id %></div>
                            </div>
                          </div>
                          <div class="flex items-center gap-2">
                            <.badge variant="outline" class="text-[9px] bg-blue-500/10 text-blue-400 border-blue-500/15">
                              <%= if squad, do: squad.name, else: "Unknown squad" %>
                            </.badge>
                          </div>
                        </div>
                      <% end %>
                    </div>
                  </div>
                <% end %>
              <% end %>
            </div>

            <%!-- Fleet ID for reference --%>
            <div class="text-[10px] text-zinc-600 font-mono pt-4 border-t border-zinc-800">
              Fleet ID: <%= @fleet_detail.id %>
            </div>
          </div>
        <% else %>
          <%!-- No fleet selected --%>
          <div class="flex-1 flex items-center justify-center h-full">
            <div class="text-center">
              <div class="w-14 h-14 rounded-2xl bg-zinc-800 flex items-center justify-center mb-4 mx-auto">
                <Icons.layers class="w-6 h-6 text-zinc-600" />
              </div>
              <p class="font-medium text-zinc-400">Select a fleet</p>
              <p class="text-sm text-zinc-500 mt-1">Choose from the list or create a new one</p>
            </div>
          </div>
        <% end %>
      </div>

      <%!-- Fleet create/edit modal --%>
      <%= if @fleet_form_open do %>
        <div class="fixed inset-0 z-[60] flex items-center justify-center animate-fade-in">
          <div class="absolute inset-0 bg-black/60 backdrop-blur-sm" phx-click="close_fleet_form"></div>
          <div class="relative w-full max-w-md mx-4 bg-zinc-900 border border-zinc-800 rounded-xl shadow-2xl">
            <div class="px-6 py-4 border-b border-zinc-800">
              <h3 class="text-sm font-semibold text-zinc-100">
                <%= if @fleet_form_mode == :create, do: "Create Fleet", else: "Edit Fleet" %>
              </h3>
            </div>
            <div class="px-6 py-5 space-y-4">
              <div>
                <label class="text-xs text-zinc-400 mb-1.5 block font-medium">Name</label>
                <.input
                  type="text"
                  name="fleet_name"
                  value={@fleet_form_name}
                  phx-keyup="fleet_form_name"
                  placeholder="e.g. Production, Staging, Dev"
                  autofocus
                  class="w-full bg-zinc-950 border-zinc-700 text-zinc-100 placeholder:text-zinc-600 focus:border-amber-500/50"
                />
              </div>
              <div>
                <label class="text-xs text-zinc-400 mb-1.5 block font-medium">Description <span class="text-zinc-600">(optional)</span></label>
                <.input
                  type="text"
                  name="fleet_description"
                  value={@fleet_form_description}
                  phx-keyup="fleet_form_description"
                  placeholder="What is this fleet for?"
                  class="w-full bg-zinc-950 border-zinc-700 text-zinc-100 placeholder:text-zinc-600 focus:border-amber-500/50"
                />
              </div>
              <div class="flex items-center justify-end gap-2 pt-2">
                <.button variant="outline" phx-click="close_fleet_form" class="border-zinc-700 text-zinc-400 hover:text-zinc-200">
                  Cancel
                </.button>
                <.button phx-click="save_fleet" class="bg-amber-500 hover:bg-amber-400 text-zinc-950 font-semibold text-xs">
                  <%= if @fleet_form_mode == :create, do: "Create Fleet", else: "Save Changes" %>
                </.button>
              </div>
            </div>
          </div>
        </div>
      <% end %>

      <%!-- Squad create modal --%>
      <%= if @squad_form_open do %>
        <div class="fixed inset-0 z-[60] flex items-center justify-center animate-fade-in">
          <div class="absolute inset-0 bg-black/60 backdrop-blur-sm" phx-click="close_squad_form"></div>
          <div class="relative w-full max-w-md mx-4 bg-zinc-900 border border-zinc-800 rounded-xl shadow-2xl">
            <div class="px-6 py-4 border-b border-zinc-800">
              <h3 class="text-sm font-semibold text-zinc-100">Create Squad</h3>
            </div>
            <div class="px-6 py-5 space-y-4">
              <div>
                <label class="text-xs text-zinc-400 mb-1.5 block font-medium">Squad Name</label>
                <.input
                  type="text"
                  name="squad_name"
                  value={@squad_form_name}
                  phx-keyup="squad_form_name"
                  placeholder="e.g. DevOps, Research, Frontend"
                  autofocus
                  class="w-full bg-zinc-950 border-zinc-700 text-zinc-100 placeholder:text-zinc-600 focus:border-amber-500/50"
                />
              </div>
              <div class="flex items-center justify-end gap-2 pt-2">
                <.button variant="outline" phx-click="close_squad_form" class="border-zinc-700 text-zinc-400 hover:text-zinc-200">
                  Cancel
                </.button>
                <.button phx-click="save_squad" class="bg-amber-500 hover:bg-amber-400 text-zinc-950 font-semibold text-xs">
                  Create Squad
                </.button>
              </div>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # ══════════════════════════════════════════════════════════
  # Page: Roles
  # ══════════════════════════════════════════════════════════

  defp render_squads(assigns) do
    ~H"""
    <div class="h-full flex animate-fade-in">
      <%!-- Squad list panel --%>
      <div class="w-72 border-r border-zinc-800 flex flex-col overflow-hidden shrink-0 bg-zinc-900">
        <div class="px-4 py-4 border-b border-zinc-800">
          <div class="flex items-center justify-between mb-1">
            <h2 class="text-sm font-semibold text-zinc-100">Squads</h2>
            <.button variant="outline" size="sm" phx-click="open_squad_create"
              class="h-7 px-2.5 text-[10px] border-amber-500/30 text-amber-400 hover:bg-amber-500/10">
              <Icons.plus class="w-3 h-3 mr-1" /> New Squad
            </.button>
          </div>
          <p class="text-[11px] text-zinc-500"><%= length(@squads) %> squad<%= if length(@squads) != 1, do: "s" %></p>
        </div>

        <div class="flex-1 overflow-y-auto p-2 space-y-1">
          <%= for squad <- @squads do %>
            <% member_count = length(squad.members || []) %>
            <% leader = get_squad_leader(squad, Hub.Fleets.squad_agents(squad.id)) %>
            <button
              phx-click="select_squad"
              phx-value-id={squad.id}
              class={"w-full text-left px-3 py-2.5 rounded-lg transition-colors duration-150 group " <>
                if(@selected_squad && @selected_squad.id == squad.id, do: "bg-zinc-800 border border-zinc-700", else: "hover:bg-zinc-800/50 border border-transparent")}
            >
              <div class="flex items-center justify-between">
                <div class="min-w-0 flex-1">
                  <div class="text-sm font-medium text-zinc-200 truncate"><%= squad.name %></div>
                  <div class="flex items-center gap-2 mt-0.5">
                    <div class="flex items-center gap-1">
                      <Icons.users class="w-3 h-3 text-zinc-600" />
                      <span class="text-[10px] text-zinc-500"><%= member_count %></span>
                    </div>
                    <%= if leader do %>
                      <span class="text-[10px] text-amber-500/70">👑 <%= leader.name || leader.agent_id %></span>
                    <% end %>
                  </div>
                </div>
              </div>
              <%= if squad.capabilities != [] do %>
                <div class="flex flex-wrap gap-1 mt-1.5">
                  <%= for cap <- Enum.take(squad.capabilities || [], 3) do %>
                    <span class="text-[9px] px-1.5 py-0.5 rounded bg-blue-500/10 text-blue-400 border border-blue-500/15"><%= cap %></span>
                  <% end %>
                  <%= if length(squad.capabilities || []) > 3 do %>
                    <span class="text-[9px] text-zinc-600">+<%= length(squad.capabilities) - 3 %></span>
                  <% end %>
                </div>
              <% end %>
            </button>
          <% end %>

          <%= if @squads == [] do %>
            <div class="text-center py-8">
              <Icons.users class="w-8 h-8 text-zinc-700 mx-auto mb-2" />
              <p class="text-xs text-zinc-600">No squads yet</p>
              <p class="text-[10px] text-zinc-700 mt-1">Create a squad to organize agents</p>
            </div>
          <% end %>
        </div>
      </div>

      <%!-- Squad detail panel --%>
      <div class="flex-1 overflow-y-auto">
        <%= if @selected_squad do %>
          <% squad = @selected_squad %>
          <% leader = get_squad_leader(squad, @selected_squad_members) %>
          <% description = squad_description(squad) %>
          <div class="p-6 space-y-6">
            <%!-- Header --%>
            <div class="flex items-start justify-between">
              <div class="flex items-center gap-3">
                <div class="w-10 h-10 rounded-xl bg-blue-500/15 border border-blue-500/25 flex items-center justify-center">
                  <Icons.users class="w-5 h-5 text-blue-400" />
                </div>
                <div>
                  <input
                    type="text"
                    value={squad.name}
                    phx-blur="update_squad_name"
                    class="text-lg font-semibold text-zinc-100 bg-transparent border-none outline-none focus:ring-1 focus:ring-amber-500/30 rounded px-1 -ml-1"
                  />
                  <div class="flex items-center gap-2 mt-0.5">
                    <span class="text-[10px] text-zinc-600 font-mono"><%= squad.group_id %></span>
                    <%= if leader do %>
                      <span class="text-[10px] text-amber-400">👑 <%= leader.name || leader.agent_id %></span>
                    <% end %>
                  </div>
                </div>
              </div>
              <div class="flex items-center gap-2">
                <.button variant="outline" size="sm"
                  phx-click="delete_squad"
                  phx-value-id={squad.id}
                  data-confirm={"Delete squad \"#{squad.name}\"? Agents will be unassigned."}
                  class="h-8 text-xs border-red-500/20 text-red-400/70 hover:bg-red-500/10 hover:text-red-300">
                  <Icons.trash class="w-3.5 h-3.5 mr-1.5" /> Delete
                </.button>
              </div>
            </div>

            <%!-- Description --%>
            <div>
              <label class="text-[10px] text-zinc-500 uppercase tracking-wider font-medium mb-1 block">Description</label>
              <textarea
                rows="2"
                phx-blur="update_squad_description"
                class="w-full text-sm text-zinc-300 bg-zinc-900 border border-zinc-800 rounded-lg p-2.5 focus:border-zinc-600 focus:outline-none resize-none"
                placeholder="Squad description..."
              ><%= description %></textarea>
            </div>

            <%!-- Capabilities tag editor --%>
            <div>
              <label class="text-[10px] text-zinc-500 uppercase tracking-wider font-medium mb-2 block">Capabilities</label>
              <div class="flex flex-wrap gap-1.5 mb-2">
                <%= for cap <- (squad.capabilities || []) do %>
                  <span class="inline-flex items-center gap-1 text-[11px] px-2 py-0.5 rounded-full bg-blue-500/10 text-blue-400 border border-blue-500/20">
                    <%= cap %>
                    <button phx-click="remove_squad_detail_capability" phx-value-cap={cap} class="hover:text-red-400 ml-0.5">
                      <Icons.x class="w-3 h-3" />
                    </button>
                  </span>
                <% end %>
                <%= if (squad.capabilities || []) == [] do %>
                  <span class="text-[11px] text-zinc-600 italic">No capabilities defined</span>
                <% end %>
              </div>
              <form phx-submit="add_squad_detail_capability" class="flex gap-2">
                <input
                  type="text"
                  name="value"
                  placeholder="Add capability..."
                  class="flex-1 h-7 text-xs bg-zinc-900 border border-zinc-800 rounded px-2 text-zinc-300 focus:border-zinc-600 focus:outline-none"
                />
                <.button type="submit" variant="outline" size="sm" class="h-7 px-2 text-[10px] border-zinc-700 text-zinc-400">
                  <Icons.plus class="w-3 h-3" />
                </.button>
              </form>
            </div>

            <%!-- Stats cards --%>
            <div class="grid grid-cols-4 gap-3">
              <.card class="bg-zinc-900 border-zinc-800">
                <.card_content class="p-3 text-center">
                  <div class="text-xl font-bold text-zinc-100"><%= length(@selected_squad_members) %></div>
                  <div class="text-[10px] text-zinc-500 mt-0.5">Members</div>
                </.card_content>
              </.card>
              <.card class="bg-zinc-900 border-zinc-800">
                <.card_content class="p-3 text-center">
                  <div class="text-xl font-bold text-zinc-100"><%= length(squad.capabilities || []) %></div>
                  <div class="text-[10px] text-zinc-500 mt-0.5">Capabilities</div>
                </.card_content>
              </.card>
              <.card class="bg-zinc-900 border-zinc-800">
                <.card_content class="p-3 text-center">
                  <div class="text-xl font-bold text-zinc-100"><%= length(@selected_squad_memory) %></div>
                  <div class="text-[10px] text-zinc-500 mt-0.5">Memory Keys</div>
                </.card_content>
              </.card>
              <.card class="bg-zinc-900 border-zinc-800">
                <.card_content class="p-3 text-center">
                  <div class="text-xl font-bold text-zinc-100"><%= length(@selected_squad_activity) %></div>
                  <div class="text-[10px] text-zinc-500 mt-0.5">Activities</div>
                </.card_content>
              </.card>
            </div>

            <%!-- Tab navigation --%>
            <div class="border-b border-zinc-800">
              <div class="flex gap-4">
                <%= for {tab, label, icon} <- [{"members", "Members", :users}, {"memory", "Memory", :database}, {"activity", "Activity", :activity}] do %>
                  <button
                    phx-click="squad_detail_tab"
                    phx-value-tab={tab}
                    class={"pb-2 px-1 text-sm font-medium border-b-2 transition-colors " <>
                      if(@squad_detail_tab == tab, do: "border-amber-500 text-amber-400", else: "border-transparent text-zinc-500 hover:text-zinc-300")}
                  >
                    <div class="flex items-center gap-1.5">
                      <%= case icon do %>
                        <% :users -> %> <Icons.users class="w-3.5 h-3.5" />
                        <% :database -> %> <Icons.database class="w-3.5 h-3.5" />
                        <% :activity -> %> <Icons.activity class="w-3.5 h-3.5" />
                        <% _ -> %> <Icons.circle_dot class="w-3.5 h-3.5" />
                      <% end %>
                      <%= label %>
                    </div>
                  </button>
                <% end %>
              </div>
            </div>

            <%!-- Tab content --%>
            <%= case @squad_detail_tab do %>
              <% "members" -> %>
                <%!-- Leader section --%>
                <div class="mb-4">
                  <div class="flex items-center justify-between mb-2">
                    <label class="text-[10px] text-zinc-500 uppercase tracking-wider font-medium">Squad Leader</label>
                  </div>
                  <%= if leader do %>
                    <div class="flex items-center justify-between p-3 rounded-lg bg-amber-500/5 border border-amber-500/15">
                      <div class="flex items-center gap-2.5">
                        <div class="w-8 h-8 rounded-lg bg-amber-500/15 flex items-center justify-center text-sm font-bold text-amber-400">
                          👑
                        </div>
                        <div>
                          <div class="text-sm font-medium text-zinc-200"><%= leader.name || leader.agent_id %></div>
                          <div class="text-[10px] text-zinc-600 font-mono"><%= leader.agent_id %></div>
                        </div>
                      </div>
                    </div>
                  <% else %>
                    <div class="p-3 rounded-lg bg-zinc-900 border border-zinc-800 text-center">
                      <p class="text-[11px] text-zinc-600">No leader assigned</p>
                    </div>
                  <% end %>
                  <%= if @selected_squad_members != [] do %>
                    <div class="mt-2">
                      <select
                        phx-change="squad_set_leader"
                        name="agent-id"
                        class="w-full h-8 text-xs bg-zinc-900 border border-zinc-800 rounded-lg text-zinc-300 px-2 focus:border-zinc-600 focus:outline-none"
                      >
                        <option value="">Set leader...</option>
                        <%= for agent <- @selected_squad_members do %>
                          <option value={agent.agent_id}><%= agent.name || agent.agent_id %></option>
                        <% end %>
                      </select>
                    </div>
                  <% end %>
                </div>

                <%!-- Members list --%>
                <div>
                  <div class="flex items-center justify-between mb-3">
                    <label class="text-[10px] text-zinc-500 uppercase tracking-wider font-medium">Members (<%= length(@selected_squad_members) %>)</label>
                  </div>

                  <%= if @selected_squad_members != [] do %>
                    <div class="space-y-1">
                      <%= for agent <- @selected_squad_members do %>
                        <% agent = Hub.Repo.preload(agent, [:role_template]) %>
                        <% is_leader = leader && leader.agent_id == agent.agent_id %>
                        <div class="flex items-center justify-between py-2 px-3 rounded-lg bg-zinc-900 border border-zinc-800 group">
                          <div class="flex items-center gap-2.5">
                            <div class={"w-6 h-6 rounded-lg flex items-center justify-center text-[10px] font-bold " <>
                              if(is_leader, do: "bg-amber-500/15 text-amber-400", else: "bg-zinc-800 text-zinc-400")}>
                              <%= if is_leader, do: "👑", else: String.first(agent.name || agent.agent_id) |> String.upcase() %>
                            </div>
                            <div>
                              <button
                                phx-click="navigate"
                                phx-value-view="agents"
                                phx-value-agent={agent.agent_id}
                                class="text-xs font-medium text-zinc-200 hover:text-amber-400 transition-colors"
                              >
                                <%= agent.name || agent.agent_id %>
                              </button>
                              <div class="flex items-center gap-1.5 mt-0.5">
                                <span class="text-[10px] text-zinc-600 font-mono"><%= agent.agent_id %></span>
                                <%= if agent.role_template do %>
                                  <span class="text-[9px] px-1.5 py-0 rounded bg-indigo-500/10 text-indigo-400 border border-indigo-500/15"><%= agent.role_template.name %></span>
                                <% end %>
                                <%= if agent.context_tier do %>
                                  <span class={"text-[9px] px-1.5 py-0 rounded border " <> tier_badge_class(agent.context_tier |> to_string() |> String.to_integer())}>T<%= agent.context_tier %></span>
                                <% end %>
                              </div>
                            </div>
                          </div>
                          <button
                            phx-click="squad_remove_member"
                            phx-value-agent-id={agent.agent_id}
                            class="text-[10px] text-zinc-600 hover:text-red-400 opacity-0 group-hover:opacity-100 transition-all"
                            title="Remove from squad"
                          >
                            <Icons.x class="w-3.5 h-3.5" />
                          </button>
                        </div>
                      <% end %>
                    </div>
                  <% else %>
                    <div class="p-4 rounded-lg bg-zinc-900 border border-zinc-800 text-center">
                      <Icons.users class="w-6 h-6 text-zinc-700 mx-auto mb-1" />
                      <p class="text-[11px] text-zinc-600">No members in this squad</p>
                    </div>
                  <% end %>

                  <%!-- Add member --%>
                  <div class="mt-3">
                    <% all_agents = load_registered_agents_detail(@fleet_id) %>
                    <% available = Enum.filter(all_agents, fn a -> is_nil(a.squad_id) || a.squad_id != squad.id end) %>
                    <%= if available != [] do %>
                      <select
                        phx-change="squad_add_member"
                        name="agent-id"
                        class="w-full h-8 text-xs bg-zinc-900 border border-zinc-800 rounded-lg text-zinc-300 px-2 focus:border-zinc-600 focus:outline-none"
                      >
                        <option value="">Add member...</option>
                        <%= for agent <- available do %>
                          <option value={agent.agent_id}>
                            <%= agent.name || agent.agent_id %><%= if agent.squad_id, do: " (in another squad)", else: "" %>
                          </option>
                        <% end %>
                      </select>
                    <% end %>
                  </div>
                </div>

              <% "memory" -> %>
                <%!-- Memory browser --%>
                <div>
                  <div class="flex items-center gap-2 mb-3">
                    <input
                      type="text"
                      phx-keyup="squad_memory_search"
                      value={@squad_memory_filter}
                      placeholder="Search memory keys..."
                      class="flex-1 h-8 text-xs bg-zinc-900 border border-zinc-800 rounded-lg text-zinc-300 px-3 focus:border-zinc-600 focus:outline-none"
                    />
                  </div>

                  <%= if @selected_squad_memory != [] do %>
                    <div class="space-y-1">
                      <%= for entry <- @selected_squad_memory do %>
                        <div class="p-3 rounded-lg bg-zinc-900 border border-zinc-800 group">
                          <div class="flex items-center justify-between mb-1">
                            <span class="text-xs font-medium text-zinc-200 font-mono"><%= entry["key"] %></span>
                            <div class="flex items-center gap-2">
                              <%= if entry["updated_at"] do %>
                                <span class="text-[10px] text-zinc-600"><%= entry["updated_at"] |> String.slice(0..18) %></span>
                              <% end %>
                              <button
                                phx-click="squad_memory_delete"
                                phx-value-key={entry["key"]}
                                data-confirm={"Delete memory key \"#{entry["key"]}\"?"}
                                class="text-zinc-600 hover:text-red-400 opacity-0 group-hover:opacity-100 transition-all"
                              >
                                <Icons.trash class="w-3 h-3" />
                              </button>
                            </div>
                          </div>
                          <div class="text-[11px] text-zinc-400 font-mono truncate max-w-md">
                            <%= String.slice(entry["value"] || "", 0..200) %><%= if String.length(entry["value"] || "") > 200, do: "…" %>
                          </div>
                          <div class="flex items-center gap-2 mt-1">
                            <%= if entry["type"] do %>
                              <span class="text-[9px] px-1.5 py-0 rounded bg-zinc-800 text-zinc-500"><%= entry["type"] %></span>
                            <% end %>
                            <%= if entry["author"] do %>
                              <span class="text-[9px] text-zinc-600">by <%= entry["author"] %></span>
                            <% end %>
                            <%= for tag <- (entry["tags"] || []) do %>
                              <span class="text-[9px] px-1 py-0 rounded bg-purple-500/10 text-purple-400"><%= tag %></span>
                            <% end %>
                          </div>
                        </div>
                      <% end %>
                    </div>
                  <% else %>
                    <div class="p-6 rounded-lg bg-zinc-900 border border-zinc-800 text-center">
                      <Icons.database class="w-6 h-6 text-zinc-700 mx-auto mb-1" />
                      <p class="text-[11px] text-zinc-600">No squad memory entries</p>
                      <p class="text-[10px] text-zinc-700 mt-0.5">Memory will appear when agents write to squad-scoped storage</p>
                    </div>
                  <% end %>
                </div>

              <% "activity" -> %>
                <%!-- Activity feed --%>
                <div>
                  <%= if @selected_squad_activity != [] do %>
                    <div class="space-y-1">
                      <%= for act <- Enum.take(@selected_squad_activity, 30) do %>
                        <div class="py-2 px-3 rounded-lg bg-zinc-900 border border-zinc-800">
                          <div class="flex items-center justify-between">
                            <div class="flex items-center gap-2">
                              <Icons.activity class="w-3 h-3 text-zinc-600" />
                              <span class="text-xs text-zinc-300"><%= Map.get(act, :agent_id) || Map.get(act, "agent_id") || "Unknown" %></span>
                              <span class="text-[11px] text-zinc-500"><%= Map.get(act, :type) || Map.get(act, "type") || "" %></span>
                            </div>
                            <span class="text-[10px] text-zinc-600">
                              <%= if ts = (Map.get(act, :timestamp) || Map.get(act, "timestamp")) do %>
                                <%= if is_binary(ts), do: String.slice(ts, 11..18), else: "" %>
                              <% end %>
                            </span>
                          </div>
                          <%= if summary = (Map.get(act, :summary) || Map.get(act, "summary")) do %>
                            <p class="text-[11px] text-zinc-500 mt-0.5 truncate"><%= String.slice(summary, 0..150) %></p>
                          <% end %>
                        </div>
                      <% end %>
                    </div>
                  <% else %>
                    <div class="p-6 rounded-lg bg-zinc-900 border border-zinc-800 text-center">
                      <Icons.activity class="w-6 h-6 text-zinc-700 mx-auto mb-1" />
                      <p class="text-[11px] text-zinc-600">No recent activity from squad members</p>
                    </div>
                  <% end %>
                </div>

              <% _ -> %>
                <div></div>
            <% end %>

            <%!-- Squad ID --%>
            <div class="text-[10px] text-zinc-600 font-mono pt-4 border-t border-zinc-800">
              Squad ID: <%= squad.id %> · Group ID: <%= squad.group_id %>
            </div>
          </div>
        <% else %>
          <%!-- No squad selected --%>
          <div class="flex-1 flex items-center justify-center h-full">
            <div class="text-center">
              <div class="w-14 h-14 rounded-2xl bg-zinc-800 flex items-center justify-center mb-4 mx-auto">
                <Icons.users class="w-6 h-6 text-zinc-600" />
              </div>
              <p class="font-medium text-zinc-400">Select a squad</p>
              <p class="text-sm text-zinc-500 mt-1">Choose from the list or create a new one</p>
            </div>
          </div>
        <% end %>
      </div>

      <%!-- Create squad modal --%>
      <%= if @squad_create_form_open do %>
        <div class="fixed inset-0 z-[60] flex items-center justify-center animate-fade-in">
          <div class="absolute inset-0 bg-black/60 backdrop-blur-sm" phx-click="close_squad_create"></div>
          <div class="relative w-full max-w-md mx-4 bg-zinc-900 border border-zinc-800 rounded-xl shadow-2xl">
            <div class="px-6 py-4 border-b border-zinc-800">
              <h3 class="text-sm font-semibold text-zinc-100">Create Squad</h3>
            </div>
            <div class="p-6 space-y-4">
              <div>
                <label class="text-xs text-zinc-400 mb-1.5 block font-medium">Name</label>
                <input
                  type="text"
                  phx-keyup="squad_create_name"
                  value={@squad_view_form_name}
                  placeholder="e.g. DevOps Squad"
                  class="w-full h-9 text-sm bg-zinc-950 border border-zinc-800 rounded-lg text-zinc-200 px-3 focus:border-zinc-600 focus:outline-none"
                />
              </div>
              <div>
                <label class="text-xs text-zinc-400 mb-1.5 block font-medium">Description</label>
                <textarea
                  rows="2"
                  phx-keyup="squad_create_description"
                  placeholder="What does this squad do?"
                  class="w-full text-sm bg-zinc-950 border border-zinc-800 rounded-lg text-zinc-200 p-3 focus:border-zinc-600 focus:outline-none resize-none"
                ><%= @squad_view_form_description %></textarea>
              </div>
              <div>
                <label class="text-xs text-zinc-400 mb-1.5 block font-medium">Capabilities</label>
                <div class="flex flex-wrap gap-1.5 mb-2">
                  <%= for cap <- @squad_view_form_capabilities do %>
                    <span class="inline-flex items-center gap-1 text-[11px] px-2 py-0.5 rounded-full bg-blue-500/10 text-blue-400 border border-blue-500/20">
                      <%= cap %>
                      <button type="button" phx-click="remove_squad_capability" phx-value-cap={cap} class="hover:text-red-400">
                        <Icons.x class="w-3 h-3" />
                      </button>
                    </span>
                  <% end %>
                </div>
                <div class="flex gap-2">
                  <input
                    type="text"
                    phx-keyup="squad_capability_input"
                    value={@squad_capability_input}
                    placeholder="Add capability..."
                    class="flex-1 h-8 text-xs bg-zinc-950 border border-zinc-800 rounded px-2 text-zinc-300 focus:border-zinc-600 focus:outline-none"
                    phx-keydown="add_squad_capability"
                    phx-key="Enter"
                  />
                  <.button type="button" variant="outline" size="sm" phx-click="add_squad_capability" class="h-8 px-2 border-zinc-700 text-zinc-400">
                    Add
                  </.button>
                </div>
              </div>
            </div>
            <div class="px-6 py-4 border-t border-zinc-800 flex justify-end gap-2">
              <.button variant="outline" size="sm" phx-click="close_squad_create" class="h-9 px-4 border-zinc-700 text-zinc-400 hover:text-zinc-200">Cancel</.button>
              <.button variant="outline" size="sm" phx-click="save_new_squad" class="h-9 px-4 border-amber-500/30 text-amber-400 hover:bg-amber-500/10">Create Squad</.button>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp render_roles(assigns) do
    ~H"""
    <div class="h-full flex flex-col animate-fade-in">
      <%!-- Header --%>
      <div class="px-6 py-4 border-b border-zinc-800 shrink-0">
        <div class="flex items-center justify-between">
          <div>
            <h2 class="text-lg font-semibold text-zinc-100">Roles</h2>
            <p class="text-sm text-zinc-500"><%= length(@roles) %> role templates</p>
          </div>
          <.button variant="outline" size="sm" phx-click="open_role_form" phx-value-mode="create" class="h-8 px-3 border-amber-500/30 text-amber-400 hover:bg-amber-500/10 hover:text-amber-300">
            <Icons.plus class="w-3.5 h-3.5 mr-1.5" /> Create Custom Role
          </.button>
        </div>
      </div>

      <%!-- Roles Grid --%>
      <div class="flex-1 overflow-auto p-6">
        <%= if @roles == [] do %>
          <Components.empty_state message="No roles defined" subtitle="Create a custom role or seed predefined roles" icon={:shield} />
        <% else %>
          <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
            <%= for role <- @roles do %>
              <.card
                phx-click="select_role"
                phx-value-id={role.id}
                class={"bg-zinc-900 border-zinc-800 hover:border-zinc-700 cursor-pointer transition-all duration-200 " <> if(@selected_role && @selected_role.id == role.id, do: "border-amber-500/40", else: "")}
              >
                <.card_content class="p-4">
                  <div class="flex items-start justify-between mb-3">
                    <div class="flex items-center gap-2.5">
                      <div class={"p-2 rounded-lg " <> if(role.is_predefined, do: "bg-blue-500/15 text-blue-400", else: "bg-amber-500/15 text-amber-400")}>
                        <Icons.shield class="w-4 h-4" />
                      </div>
                      <div>
                        <div class="text-sm font-medium text-zinc-200 flex items-center gap-1.5">
                          <%= role.name %>
                          <%= if role.is_predefined do %>
                            <span title="Predefined (read-only)" class="text-xs">🔒</span>
                          <% end %>
                        </div>
                        <div class="text-[11px] text-zinc-500 font-mono"><%= role.slug %></div>
                      </div>
                    </div>
                  </div>

                  <%!-- Tier badge --%>
                  <div class="flex items-center gap-2 mb-3">
                    <.badge variant="outline" class={"text-[10px] px-1.5 py-0.5 " <> role_tier_style(role.context_injection_tier)}>
                      <%= role.context_injection_tier || "auto" %>
                    </.badge>
                    <%= if role.capabilities && length(role.capabilities) > 0 do %>
                      <.badge variant="secondary" class="text-[10px] px-1.5 py-0.5 bg-zinc-800 text-zinc-400">
                        <%= length(role.capabilities) %> capabilities
                      </.badge>
                    <% end %>
                    <%= if role.constraints && length(role.constraints) > 0 do %>
                      <.badge variant="secondary" class="text-[10px] px-1.5 py-0.5 bg-zinc-800 text-zinc-400">
                        <%= length(role.constraints) %> constraints
                      </.badge>
                    <% end %>
                  </div>

                  <%!-- System prompt preview --%>
                  <p class="text-xs text-zinc-500 line-clamp-2 mb-3"><%= String.slice(role.system_prompt || "", 0..120) %><%= if String.length(role.system_prompt || "") > 120, do: "…" %></p>

                  <%!-- Action buttons for custom roles --%>
                  <%= unless role.is_predefined do %>
                    <div class="flex gap-2 pt-2 border-t border-zinc-800">
                      <.button variant="ghost" size="sm" phx-click="open_role_form" phx-value-mode="edit" phx-value-role-id={role.id} class="h-7 text-xs text-zinc-400 hover:text-zinc-200">
                        <Icons.pencil class="w-3 h-3 mr-1" /> Edit
                      </.button>
                      <.button variant="ghost" size="sm" phx-click="delete_role" phx-value-id={role.id} class="h-7 text-xs text-red-400/70 hover:text-red-400" data-confirm="Delete this role? Agents using it will be unassigned.">
                        <Icons.trash class="w-3 h-3 mr-1" /> Delete
                      </.button>
                    </div>
                  <% end %>
                </.card_content>
              </.card>
            <% end %>
          </div>
        <% end %>
      </div>

      <%!-- Role Detail Slide-out --%>
      <%= if @role_detail_open && @selected_role do %>
        <div class="fixed inset-0 z-50 flex justify-end">
          <div class="absolute inset-0 bg-black/40 backdrop-blur-sm" phx-click="close_role_detail"></div>
          <div class="relative w-full max-w-lg bg-zinc-900 border-l border-zinc-800 overflow-y-auto animate-slide-in-right">
            <div class="p-6">
              <%!-- Header --%>
              <div class="flex items-start justify-between mb-6">
                <div>
                  <div class="flex items-center gap-2">
                    <h3 class="text-lg font-semibold text-zinc-100"><%= @selected_role.name %></h3>
                    <%= if @selected_role.is_predefined do %>
                      <.badge variant="outline" class="text-[10px] bg-blue-500/10 text-blue-400 border-blue-500/20">Predefined 🔒</.badge>
                    <% else %>
                      <.badge variant="outline" class="text-[10px] bg-amber-500/10 text-amber-400 border-amber-500/20">Custom</.badge>
                    <% end %>
                  </div>
                  <p class="text-sm text-zinc-500 font-mono mt-1"><%= @selected_role.slug %></p>
                </div>
                <.button variant="ghost" size="icon" phx-click="close_role_detail" class="h-8 w-8 text-zinc-400 hover:text-zinc-200">
                  <Icons.x class="w-4 h-4" />
                </.button>
              </div>

              <%!-- Tier --%>
              <div class="mb-5">
                <div class="text-xs font-semibold text-zinc-500 uppercase tracking-wider mb-2">Context Injection Tier</div>
                <.badge variant="outline" class={"text-xs px-2 py-1 " <> role_tier_style(@selected_role.context_injection_tier)}>
                  <%= @selected_role.context_injection_tier || "auto" %>
                </.badge>
              </div>

              <%!-- System Prompt --%>
              <div class="mb-5">
                <div class="text-xs font-semibold text-zinc-500 uppercase tracking-wider mb-2">System Prompt</div>
                <div class="bg-zinc-950 border border-zinc-800 rounded-lg p-3 max-h-48 overflow-y-auto">
                  <pre class="text-xs text-zinc-300 whitespace-pre-wrap font-mono"><%= @selected_role.system_prompt %></pre>
                </div>
              </div>

              <%!-- Capabilities --%>
              <%= if @selected_role.capabilities && @selected_role.capabilities != [] do %>
                <div class="mb-5">
                  <div class="text-xs font-semibold text-zinc-500 uppercase tracking-wider mb-2">Capabilities</div>
                  <div class="flex flex-wrap gap-1.5">
                    <%= for cap <- @selected_role.capabilities do %>
                      <.badge variant="outline" class="text-[11px] px-2 py-0.5 bg-green-500/10 text-green-400 border-green-500/20"><%= cap %></.badge>
                    <% end %>
                  </div>
                </div>
              <% end %>

              <%!-- Constraints --%>
              <%= if @selected_role.constraints && @selected_role.constraints != [] do %>
                <div class="mb-5">
                  <div class="text-xs font-semibold text-zinc-500 uppercase tracking-wider mb-2">Constraints</div>
                  <div class="flex flex-wrap gap-1.5">
                    <%= for c <- @selected_role.constraints do %>
                      <.badge variant="outline" class="text-[11px] px-2 py-0.5 bg-red-500/10 text-red-400 border-red-500/20"><%= c %></.badge>
                    <% end %>
                  </div>
                </div>
              <% end %>

              <%!-- Tools Allowed --%>
              <%= if @selected_role.tools_allowed && @selected_role.tools_allowed != [] do %>
                <div class="mb-5">
                  <div class="text-xs font-semibold text-zinc-500 uppercase tracking-wider mb-2">Tools Allowed</div>
                  <div class="flex flex-wrap gap-1.5">
                    <%= for t <- @selected_role.tools_allowed do %>
                      <.badge variant="outline" class="text-[11px] px-2 py-0.5 bg-purple-500/10 text-purple-400 border-purple-500/20"><%= t %></.badge>
                    <% end %>
                  </div>
                </div>
              <% end %>

              <%!-- Escalation Rules --%>
              <%= if @selected_role.escalation_rules && @selected_role.escalation_rules != "" do %>
                <div class="mb-5">
                  <div class="text-xs font-semibold text-zinc-500 uppercase tracking-wider mb-2">Escalation Rules</div>
                  <div class="bg-zinc-950 border border-zinc-800 rounded-lg p-3">
                    <pre class="text-xs text-zinc-300 whitespace-pre-wrap font-mono"><%= @selected_role.escalation_rules %></pre>
                  </div>
                </div>
              <% end %>

              <.separator class="my-5" />

              <%!-- Assign to Agent --%>
              <div class="mb-4">
                <div class="text-xs font-semibold text-zinc-500 uppercase tracking-wider mb-2">Assign to Agent</div>
                <div class="flex gap-2">
                  <select
                    phx-change="role_assign_agent_select"
                    name="agent_id"
                    class="flex-1 h-9 text-sm bg-zinc-950 border border-zinc-800 rounded-lg text-zinc-200 px-3 focus:border-zinc-600 focus:outline-none"
                  >
                    <option value="">Select agent…</option>
                    <%= for {agent_id, meta} <- @agents do %>
                      <option value={agent_id} selected={@role_assign_agent_id == agent_id}>
                        <%= meta[:name] || agent_id %>
                      </option>
                    <% end %>
                  </select>
                  <.button variant="outline" size="sm" phx-click="role_assign_to_agent" class="h-9 px-3 border-amber-500/30 text-amber-400 hover:bg-amber-500/10">
                    Assign
                  </.button>
                </div>
              </div>

              <%!-- Edit/Delete for custom --%>
              <%= unless @selected_role.is_predefined do %>
                <div class="flex gap-2 pt-4 border-t border-zinc-800">
                  <.button variant="outline" size="sm" phx-click="open_role_form" phx-value-mode="edit" phx-value-role-id={@selected_role.id} class="flex-1 h-9 border-zinc-700 text-zinc-300 hover:bg-zinc-800">
                    <Icons.pencil class="w-3.5 h-3.5 mr-1.5" /> Edit Role
                  </.button>
                  <.button variant="outline" size="sm" phx-click="delete_role" phx-value-id={@selected_role.id} class="h-9 px-3 border-red-500/30 text-red-400 hover:bg-red-500/10" data-confirm="Delete this role?">
                    <Icons.trash class="w-3.5 h-3.5" />
                  </.button>
                </div>
              <% end %>
            </div>
          </div>
        </div>
      <% end %>

      <%!-- Create/Edit Role Modal --%>
      <%= if @role_form_open do %>
        <div class="fixed inset-0 z-50 flex items-center justify-center">
          <div class="absolute inset-0 bg-black/50 backdrop-blur-sm" phx-click="close_role_form"></div>
          <div class="relative w-full max-w-2xl max-h-[85vh] bg-zinc-900 border border-zinc-800 rounded-xl shadow-2xl overflow-y-auto animate-fade-in">
            <div class="p-6">
              <div class="flex items-center justify-between mb-6">
                <h3 class="text-lg font-semibold text-zinc-100">
                  <%= if @role_form_mode == :create, do: "Create Custom Role", else: "Edit Role" %>
                </h3>
                <.button variant="ghost" size="icon" phx-click="close_role_form" class="h-8 w-8 text-zinc-400 hover:text-zinc-200">
                  <Icons.x class="w-4 h-4" />
                </.button>
              </div>

              <div class="space-y-5">
                <%!-- Name --%>
                <div>
                  <label class="text-xs text-zinc-400 mb-1.5 block font-medium">Name</label>
                  <.input type="text" value={@role_form.name} phx-keyup="role_form_field" phx-value-field="name" placeholder="e.g. Code Reviewer" class="w-full bg-zinc-950 border-zinc-800 text-zinc-100" />
                </div>

                <%!-- Slug --%>
                <div>
                  <label class="text-xs text-zinc-400 mb-1.5 block font-medium">Slug</label>
                  <.input type="text" value={@role_form.slug} phx-keyup="role_form_field" phx-value-field="slug" placeholder="code-reviewer" class="w-full bg-zinc-950 border-zinc-800 text-zinc-100 font-mono" />
                  <p class="text-[10px] text-zinc-600 mt-1">Lowercase alphanumeric with hyphens. Auto-generated from name.</p>
                </div>

                <%!-- System Prompt --%>
                <div>
                  <label class="text-xs text-zinc-400 mb-1.5 block font-medium">System Prompt</label>
                  <textarea
                    phx-keyup="role_form_field"
                    phx-value-field="system_prompt"
                    rows="6"
                    placeholder="You are a..."
                    class="w-full bg-zinc-950 border border-zinc-800 rounded-lg text-zinc-100 text-sm p-3 font-mono resize-y focus:border-zinc-600 focus:outline-none"
                  ><%= @role_form.system_prompt %></textarea>
                </div>

                <%!-- Capabilities (tag input) --%>
                <div>
                  <label class="text-xs text-zinc-400 mb-1.5 block font-medium">Capabilities</label>
                  <div class="flex flex-wrap gap-1.5 mb-2">
                    <%= for cap <- @role_form.capabilities do %>
                      <.badge variant="outline" class="text-[11px] px-2 py-0.5 bg-green-500/10 text-green-400 border-green-500/20 flex items-center gap-1">
                        <%= cap %>
                        <button type="button" phx-click="role_remove_capability" phx-value-value={cap} class="hover:text-green-200">×</button>
                      </.badge>
                    <% end %>
                  </div>
                  <div class="flex gap-2">
                    <.input type="text" value={@role_form.new_capability} phx-keyup="role_form_field" phx-value-field="new_capability" placeholder="Add capability…" class="flex-1 bg-zinc-950 border-zinc-800 text-zinc-100" />
                    <.button variant="outline" size="sm" phx-click="role_add_capability" class="h-9 px-3 border-zinc-700 text-zinc-400 hover:text-zinc-200">Add</.button>
                  </div>
                </div>

                <%!-- Constraints (tag input) --%>
                <div>
                  <label class="text-xs text-zinc-400 mb-1.5 block font-medium">Constraints</label>
                  <div class="flex flex-wrap gap-1.5 mb-2">
                    <%= for c <- @role_form.constraints do %>
                      <.badge variant="outline" class="text-[11px] px-2 py-0.5 bg-red-500/10 text-red-400 border-red-500/20 flex items-center gap-1">
                        <%= c %>
                        <button type="button" phx-click="role_remove_constraint" phx-value-value={c} class="hover:text-red-200">×</button>
                      </.badge>
                    <% end %>
                  </div>
                  <div class="flex gap-2">
                    <.input type="text" value={@role_form.new_constraint} phx-keyup="role_form_field" phx-value-field="new_constraint" placeholder="Add constraint…" class="flex-1 bg-zinc-950 border-zinc-800 text-zinc-100" />
                    <.button variant="outline" size="sm" phx-click="role_add_constraint" class="h-9 px-3 border-zinc-700 text-zinc-400 hover:text-zinc-200">Add</.button>
                  </div>
                </div>

                <%!-- Tools Allowed (tag input) --%>
                <div>
                  <label class="text-xs text-zinc-400 mb-1.5 block font-medium">Tools Allowed</label>
                  <div class="flex flex-wrap gap-1.5 mb-2">
                    <%= for t <- @role_form.tools_allowed do %>
                      <.badge variant="outline" class="text-[11px] px-2 py-0.5 bg-purple-500/10 text-purple-400 border-purple-500/20 flex items-center gap-1">
                        <%= t %>
                        <button type="button" phx-click="role_remove_tool" phx-value-value={t} class="hover:text-purple-200">×</button>
                      </.badge>
                    <% end %>
                  </div>
                  <div class="flex gap-2">
                    <.input type="text" value={@role_form.new_tool} phx-keyup="role_form_field" phx-value-field="new_tool" placeholder="Add tool…" class="flex-1 bg-zinc-950 border-zinc-800 text-zinc-100" />
                    <.button variant="outline" size="sm" phx-click="role_add_tool" class="h-9 px-3 border-zinc-700 text-zinc-400 hover:text-zinc-200">Add</.button>
                  </div>
                </div>

                <%!-- Escalation Rules --%>
                <div>
                  <label class="text-xs text-zinc-400 mb-1.5 block font-medium">Escalation Rules</label>
                  <textarea
                    phx-keyup="role_form_field"
                    phx-value-field="escalation_rules"
                    rows="3"
                    placeholder="Optional escalation rules…"
                    class="w-full bg-zinc-950 border border-zinc-800 rounded-lg text-zinc-100 text-sm p-3 font-mono resize-y focus:border-zinc-600 focus:outline-none"
                  ><%= @role_form.escalation_rules %></textarea>
                </div>

                <%!-- Context Injection Tier --%>
                <div>
                  <label class="text-xs text-zinc-400 mb-1.5 block font-medium">Context Injection Tier</label>
                  <select
                    phx-change="role_form_field"
                    phx-value-field="context_injection_tier"
                    name="context_injection_tier"
                    class="w-full h-9 text-sm bg-zinc-950 border border-zinc-800 rounded-lg text-zinc-200 px-3 focus:border-zinc-600 focus:outline-none"
                  >
                    <%= for tier <- ["auto", "tier1", "tier2", "tier3"] do %>
                      <option value={tier} selected={@role_form.context_injection_tier == tier}><%= tier %></option>
                    <% end %>
                  </select>
                </div>

                <%!-- Save --%>
                <div class="flex gap-3 pt-4 border-t border-zinc-800">
                  <.button phx-click="save_role" class="flex-1 bg-amber-500 hover:bg-amber-400 text-zinc-950 font-semibold h-10">
                    <%= if @role_form_mode == :create, do: "Create Role", else: "Save Changes" %>
                  </.button>
                  <.button variant="outline" phx-click="close_role_form" class="h-10 px-4 border-zinc-700 text-zinc-400 hover:text-zinc-200">
                    Cancel
                  </.button>
                </div>
              </div>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp role_tier_style("tier1"), do: "bg-green-500/10 text-green-400 border-green-500/20"
  defp role_tier_style("tier2"), do: "bg-blue-500/10 text-blue-400 border-blue-500/20"
  defp role_tier_style("tier3"), do: "bg-purple-500/10 text-purple-400 border-purple-500/20"
  defp role_tier_style(_), do: "bg-zinc-700 text-zinc-400 border-zinc-600"

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

    # Build detail lookup from registered_agents_detail
    detail_map = Map.new(assigns.registered_agents_detail, fn a ->
      role_name = case a.role_template do
        %{name: n} when is_binary(n) -> n
        _ -> nil
      end
      squad_name = case a.squad do
        %{name: n} when is_binary(n) -> n
        _ -> nil
      end
      tier = try do tier_for_agent(a) rescue _ -> 4 end
      {a.agent_id, %{role_name: role_name, squad_name: squad_name, tier: tier, role_template_id: a.role_template_id, squad_id: a.squad_id}}
    end)

    list = all_agents
      |> Enum.map(fn {id, m} -> {id, m} end)
      |> filter_agents(assigns.search_query)
      |> sort_agents(assigns.sort_by, assigns.sort_dir)

    online_count = Enum.count(assigns.agents, fn {_,m} -> m[:state] == "online" end)
    total_registered = length(assigns.registered_agents)

    assigns = assign(assigns, agents_list: list, agents_online: online_count, total_registered: total_registered, detail_map: detail_map)

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
              <.button variant="outline" size="sm" phx-click="open_wizard" class="h-8 px-3 border-amber-500/30 text-amber-400 hover:bg-amber-500/10 hover:text-amber-300">
                <Icons.plus class="w-3.5 h-3.5 mr-1.5" /> Add Agent
              </.button>
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
            <div class="flex flex-col items-center justify-center py-16 space-y-4">
              <Components.empty_state message="No agents found" subtitle="Add your first agent to get started" icon={:bot} />
              <.button variant="outline" phx-click="open_wizard" class="border-amber-500/30 text-amber-400 hover:bg-amber-500/10 hover:text-amber-300">
                <Icons.plus class="w-4 h-4 mr-2" /> Add Agent
              </.button>
            </div>
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
                  <.table_head><span class="text-[10px] font-semibold text-zinc-500 uppercase tracking-wider">Role</span></.table_head>
                  <.table_head><span class="text-[10px] font-semibold text-zinc-500 uppercase tracking-wider">Squad</span></.table_head>
                  <.table_head><span class="text-[10px] font-semibold text-zinc-500 uppercase tracking-wider">Tier</span></.table_head>
                  <.table_head><span class="text-[10px] font-semibold text-zinc-500 uppercase tracking-wider">Task</span></.table_head>
                  <.table_head>
                    <button phx-click="sort_agents" phx-value-column="framework" class="text-[10px] font-semibold text-zinc-500 uppercase tracking-wider hover:text-zinc-300 transition-colors flex items-center gap-1">
                      Framework <%= sort_arrow(@sort_by, @sort_dir, :framework) %>
                    </button>
                  </.table_head>
                </.table_row>
              </.table_header>
              <.table_body>
                <%= for {id, meta} <- @agents_list do %>
                  <% detail = Map.get(@detail_map, id, %{}) %>
                  <.table_row
                    phx-click={JS.push("select_agent_detail", value: %{"agent-id" => id}) |> JS.exec("phx-show-sheet", to: "#agent-detail-sheet")}
                    class={"cursor-pointer transition-colors duration-150 " <> if(@selected_agent == id, do: "bg-amber-500/5", else: "hover:bg-zinc-800/50")}
                  >
                    <.table_cell>
                      <div class="flex items-center gap-2.5">
                        <div class={"w-8 h-8 rounded-lg flex items-center justify-center text-xs font-bold " <> Components.avatar_bg(meta[:state])}>
                          <%= Components.avatar_initial(meta[:name] || id) %>
                        </div>
                        <div>
                          <div class="text-sm font-medium text-zinc-200"><%= meta[:name] || id %></div>
                          <div class="text-[10px] text-zinc-600 font-mono truncate max-w-[140px]"><%= id %></div>
                        </div>
                      </div>
                    </.table_cell>
                    <.table_cell>
                      <div class="flex items-center gap-1.5">
                        <span class={"w-2 h-2 rounded-full " <> Components.state_dot(meta[:state]) <> if(meta[:state] in ["online", "busy"], do: " animate-pulse-dot", else: "")}></span>
                        <.badge variant="outline" class={"text-[10px] " <> Components.state_badge(meta[:state])}><%= meta[:state] || "unknown" %></.badge>
                      </div>
                    </.table_cell>
                    <.table_cell>
                      <%= if detail[:role_name] do %>
                        <.badge variant="outline" class="text-[10px] px-1.5 py-0.5 bg-indigo-500/10 text-indigo-400 border-indigo-500/15"><%= detail[:role_name] %></.badge>
                      <% else %>
                        <span class="text-[10px] text-zinc-600 italic">No role</span>
                      <% end %>
                    </.table_cell>
                    <.table_cell>
                      <%= if detail[:squad_name] do %>
                        <.badge variant="outline" class="text-[10px] px-1.5 py-0.5 bg-cyan-500/10 text-cyan-400 border-cyan-500/15"><%= detail[:squad_name] %></.badge>
                      <% else %>
                        <span class="text-[10px] text-zinc-600 italic">Unassigned</span>
                      <% end %>
                    </.table_cell>
                    <.table_cell>
                      <%= if detail[:tier] do %>
                        <span class={"text-[9px] px-1.5 py-0.5 rounded font-bold border " <> tier_badge_class(detail[:tier])}>T<%= detail[:tier] %></span>
                      <% else %>
                        <span class="text-[10px] text-zinc-600">—</span>
                      <% end %>
                    </.table_cell>
                    <.table_cell>
                      <span class="text-xs text-zinc-400 truncate block max-w-[180px]"><%= meta[:task] || "—" %></span>
                    </.table_cell>
                    <.table_cell>
                      <span class="text-xs text-zinc-400"><%= meta[:framework] || "—" %></span>
                    </.table_cell>
                  </.table_row>
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
            <% agent_detail = Map.get(@detail_map, @selected_agent, %{}) %>
            <div class="p-5 space-y-5 overflow-y-auto max-h-screen">
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
                      <div class="flex items-center gap-2">
                        <span class="text-sm font-semibold text-zinc-100"><%= dm[:name] || @selected_agent %></span>
                        <%= if agent_detail[:tier] do %>
                          <span class={"text-[9px] px-1.5 py-0.5 rounded font-bold border " <> tier_badge_class(agent_detail[:tier])}>T<%= agent_detail[:tier] %></span>
                        <% end %>
                      </div>
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

              <%!-- Role Section --%>
              <div>
                <div class="flex items-center justify-between mb-2">
                  <span class="text-[10px] font-semibold text-zinc-500 uppercase tracking-wider">Role</span>
                  <button phx-click="toggle_agent_role_edit" phx-value-agent-id={@selected_agent}
                    class="text-[10px] text-amber-400 hover:text-amber-300">
                    <%= if @agent_role_editing, do: "Cancel", else: "Change" %>
                  </button>
                </div>
                <%= if @agent_role_editing do %>
                  <div class="space-y-1">
                    <%= for role <- @available_roles do %>
                      <button phx-click="assign_agent_role" phx-value-agent-id={@selected_agent} phx-value-role-id={role.id}
                        class={"w-full text-left px-2.5 py-1.5 rounded text-xs transition-colors " <>
                          if(agent_detail[:role_template_id] == role.id, do: "bg-indigo-500/15 text-indigo-400", else: "text-zinc-400 hover:bg-zinc-800")}>
                        <%= role.name %>
                      </button>
                    <% end %>
                    <button phx-click="assign_agent_role" phx-value-agent-id={@selected_agent} phx-value-role-id=""
                      class="w-full text-left px-2.5 py-1.5 rounded text-xs text-zinc-600 hover:bg-zinc-800">
                      Remove role
                    </button>
                  </div>
                <% else %>
                  <%= if agent_detail[:role_name] do %>
                    <.badge variant="outline" class="text-[10px] px-2 py-0.5 bg-indigo-500/10 text-indigo-400 border-indigo-500/15"><%= agent_detail[:role_name] %></.badge>
                  <% else %>
                    <span class="text-xs text-zinc-600 italic">No role assigned</span>
                  <% end %>
                <% end %>
              </div>

              <%!-- Squad Section --%>
              <div>
                <div class="flex items-center justify-between mb-2">
                  <span class="text-[10px] font-semibold text-zinc-500 uppercase tracking-wider">Squad</span>
                  <button phx-click="toggle_agent_squad_edit" phx-value-agent-id={@selected_agent}
                    class="text-[10px] text-amber-400 hover:text-amber-300">
                    <%= if @agent_squad_editing, do: "Cancel", else: "Change" %>
                  </button>
                </div>
                <%= if @agent_squad_editing do %>
                  <div class="space-y-1">
                    <%= for squad <- @available_squads do %>
                      <button phx-click="assign_agent_squad" phx-value-agent-id={@selected_agent} phx-value-squad-id={squad.id}
                        class={"w-full text-left px-2.5 py-1.5 rounded text-xs transition-colors " <>
                          if(agent_detail[:squad_id] == squad.id, do: "bg-cyan-500/15 text-cyan-400", else: "text-zinc-400 hover:bg-zinc-800")}>
                        <%= squad.name %>
                      </button>
                    <% end %>
                    <button phx-click="assign_agent_squad" phx-value-agent-id={@selected_agent} phx-value-squad-id=""
                      class="w-full text-left px-2.5 py-1.5 rounded text-xs text-zinc-600 hover:bg-zinc-800">
                      Remove from squad
                    </button>
                  </div>
                <% else %>
                  <%= if agent_detail[:squad_name] do %>
                    <.badge variant="outline" class="text-[10px] px-2 py-0.5 bg-cyan-500/10 text-cyan-400 border-cyan-500/15"><%= agent_detail[:squad_name] %></.badge>
                  <% else %>
                    <span class="text-xs text-zinc-600 italic">Unassigned</span>
                  <% end %>
                <% end %>
              </div>

              <%!-- Active Kanban Tasks --%>
              <div>
                <div class="text-[10px] font-semibold text-zinc-500 uppercase tracking-wider mb-2">Active Tasks</div>
                <%= if @agent_kanban_tasks == [] do %>
                  <p class="text-xs text-zinc-600 italic">No active tasks</p>
                <% else %>
                  <div class="space-y-1">
                    <%= for task <- @agent_kanban_tasks do %>
                      <div class="flex items-center gap-2 px-2 py-1.5 rounded bg-zinc-800/50 text-xs">
                        <span class="text-[9px] px-1.5 py-0.5 rounded bg-purple-500/10 text-purple-400 border border-purple-500/20 font-mono">
                          T-<%= String.slice(task.task_id || "", 0..5) %>
                        </span>
                        <span class="text-zinc-300 truncate flex-1"><%= task.title %></span>
                      </div>
                    <% end %>
                  </div>
                <% end %>
              </div>

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
  # Page: Kanban Board
  # ══════════════════════════════════════════════════════════

  defp render_kanban(assigns) do
    lanes = [
      {"backlog", "Backlog", "bg-zinc-800/50", "text-zinc-400", "border-zinc-700"},
      {"ready", "Ready", "bg-green-500/10", "text-green-400", "border-green-500/20"},
      {"in_progress", "In Progress", "bg-blue-500/10", "text-blue-400", "border-blue-500/20"},
      {"review", "Review", "bg-yellow-500/10", "text-yellow-400", "border-yellow-500/20"},
      {"done", "Done", "bg-emerald-500/10", "text-emerald-400", "border-emerald-500/20"}
    ]

    lane_counts = assigns.kanban_stats["lanes"] || %{}
    velocity_24h = assigns.kanban_stats["velocity_24h"] || 0
    avg_cycle = assigns.kanban_stats["avg_cycle_time_hours"]
    total = assigns.kanban_stats["total"] || 0
    blocked = assigns.kanban_stats["blocked"] || 0

    # Unique agents across all tasks for filter dropdown
    all_agents_in_board = assigns.kanban_board
      |> Enum.flat_map(fn {_lane, tasks} -> tasks end)
      |> Enum.map(& &1.assigned_to)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    assigns = assign(assigns,
      lanes: lanes,
      lane_counts: lane_counts,
      velocity_24h: velocity_24h,
      avg_cycle: avg_cycle,
      kb_total: total,
      kb_blocked: blocked,
      all_agents_in_board: all_agents_in_board
    )

    ~H"""
    <div class="h-full flex flex-col overflow-hidden animate-fade-in">
      <%!-- Header --%>
      <div class="px-6 py-4 border-b border-zinc-800 shrink-0">
        <div class="flex items-center justify-between mb-3">
          <div>
            <h2 class="text-lg font-semibold text-zinc-100 flex items-center gap-2">
              <Icons.kanban class="w-5 h-5 text-amber-400" />
              Kanban Board
            </h2>
            <p class="text-sm text-zinc-500">Task management and workflow</p>
          </div>
          <div class="flex items-center gap-2">
            <.button variant="outline" size="sm" phx-click="kanban_refresh"
              class="h-8 text-xs border-zinc-700 text-zinc-400 hover:text-zinc-200">
              <Icons.refresh_cw class="w-3.5 h-3.5 mr-1.5" /> Refresh
            </.button>
            <.button size="sm" phx-click="kanban_open_create"
              class="h-8 text-xs bg-amber-500 hover:bg-amber-400 text-zinc-950 font-semibold">
              <Icons.plus class="w-3.5 h-3.5 mr-1.5" /> New Task
            </.button>
          </div>
        </div>

        <%!-- Stats bar --%>
        <div class="flex items-center gap-3 text-xs flex-wrap">
          <div class="flex items-center gap-1.5 text-zinc-400">
            <span class="text-zinc-500">📊</span>
            <span>Total: <span class="text-zinc-200 font-medium"><%= @kb_total %></span></span>
          </div>
          <span class="text-zinc-700">|</span>
          <div class="flex items-center gap-1.5 text-zinc-400">
            <span>📋</span>
            <span>Backlog: <span class="text-zinc-200 font-medium"><%= @lane_counts["backlog"] || 0 %></span></span>
          </div>
          <span class="text-zinc-700">|</span>
          <div class="flex items-center gap-1.5 text-zinc-400">
            <span>🟢</span>
            <span>Ready: <span class="text-green-400 font-medium"><%= @lane_counts["ready"] || 0 %></span></span>
          </div>
          <span class="text-zinc-700">|</span>
          <div class="flex items-center gap-1.5 text-zinc-400">
            <span>🔵</span>
            <span>Active: <span class="text-blue-400 font-medium"><%= @lane_counts["in_progress"] || 0 %></span></span>
          </div>
          <span class="text-zinc-700">|</span>
          <div class="flex items-center gap-1.5 text-zinc-400">
            <span>🟡</span>
            <span>Review: <span class="text-yellow-400 font-medium"><%= @lane_counts["review"] || 0 %></span></span>
          </div>
          <span class="text-zinc-700">|</span>
          <div class="flex items-center gap-1.5 text-zinc-400">
            <span>✅</span>
            <span>Done: <span class="text-emerald-400 font-medium"><%= @lane_counts["done"] || 0 %></span></span>
          </div>
          <%= if @kb_blocked > 0 do %>
            <span class="text-zinc-700">|</span>
            <div class="flex items-center gap-1.5 text-red-400">
              <span>🚫</span>
              <span>Blocked: <span class="font-medium"><%= @kb_blocked %></span></span>
            </div>
          <% end %>
          <span class="text-zinc-700">|</span>
          <div class="flex items-center gap-1.5 text-zinc-400">
            <span>⚡</span>
            <span>Velocity: <span class="text-amber-400 font-medium"><%= @velocity_24h %>/day</span></span>
          </div>
          <%= if @avg_cycle do %>
            <span class="text-zinc-700">|</span>
            <div class="flex items-center gap-1.5 text-zinc-400">
              <span>⏱️</span>
              <span>Cycle: <span class="text-zinc-200 font-medium"><%= @avg_cycle %>h</span></span>
            </div>
          <% end %>
        </div>

        <%!-- Filters --%>
        <div class="flex items-center gap-3 mt-3">
          <div class="flex items-center gap-2 flex-1">
            <div class="relative flex-1 max-w-xs">
              <Icons.search class="w-3.5 h-3.5 text-zinc-500 absolute left-2.5 top-1/2 -translate-y-1/2" />
              <input
                type="text"
                phx-keyup="kanban_search"
                value={@kanban_filters.search}
                placeholder="Search tasks..."
                class="w-full h-8 pl-8 pr-3 text-xs bg-zinc-900 border border-zinc-800 rounded-lg text-zinc-200 placeholder:text-zinc-600 focus:border-amber-500/50 focus:outline-none focus:ring-1 focus:ring-amber-500/20"
              />
            </div>
            <select
              phx-change="kanban_filter"
              name="value"
              phx-value-field="priority"
              class="h-8 px-2.5 text-xs bg-zinc-900 border border-zinc-800 rounded-lg text-zinc-400 focus:border-amber-500/50 focus:outline-none"
            >
              <option value="" selected={is_nil(@kanban_filters.priority)}>All Priorities</option>
              <option value="critical" selected={@kanban_filters.priority == "critical"}>🔴 Critical</option>
              <option value="high" selected={@kanban_filters.priority == "high"}>🟠 High</option>
              <option value="medium" selected={@kanban_filters.priority == "medium"}>🟡 Medium</option>
              <option value="low" selected={@kanban_filters.priority == "low"}>⚪ Low</option>
            </select>
            <select
              phx-change="kanban_filter"
              name="value"
              phx-value-field="assigned_to"
              class="h-8 px-2.5 text-xs bg-zinc-900 border border-zinc-800 rounded-lg text-zinc-400 focus:border-amber-500/50 focus:outline-none"
            >
              <option value="" selected={is_nil(@kanban_filters.assigned_to)}>All Agents</option>
              <%= for agent_id <- @all_agents_in_board do %>
                <option value={agent_id} selected={@kanban_filters.assigned_to == agent_id}><%= agent_id %></option>
              <% end %>
            </select>
            <%= if @kanban_squads != [] do %>
              <select
                phx-change="kanban_filter"
                name="value"
                phx-value-field="squad_id"
                class="h-8 px-2.5 text-xs bg-zinc-900 border border-zinc-800 rounded-lg text-zinc-400 focus:border-amber-500/50 focus:outline-none"
              >
                <option value="" selected={is_nil(@kanban_filters.squad_id)}>All Squads</option>
                <%= for squad <- @kanban_squads do %>
                  <option value={squad.id} selected={@kanban_filters.squad_id == squad.id}><%= squad.name %></option>
                <% end %>
              </select>
            <% end %>
          </div>
        </div>
      </div>

      <%!-- Board --%>
      <div class="flex-1 overflow-x-auto overflow-y-hidden p-4">
        <div class="flex gap-3 h-full min-w-max">
          <%= for {lane_key, lane_label, header_bg, header_text, header_border} <- @lanes do %>
            <% tasks = Map.get(@kanban_board, lane_key, []) %>
            <div class="w-64 flex flex-col bg-zinc-900/50 rounded-xl border border-zinc-800 overflow-hidden shrink-0">
              <%!-- Lane header --%>
              <div class={"px-3 py-2.5 border-b flex items-center justify-between " <> header_bg <> " " <> header_border}>
                <div class="flex items-center gap-2">
                  <span class={"text-xs font-semibold uppercase tracking-wider " <> header_text}>
                    <%= lane_label %>
                  </span>
                  <span class="text-[10px] font-medium text-zinc-500 bg-zinc-800/80 rounded-full px-1.5 py-0.5">
                    <%= length(tasks) %>
                  </span>
                </div>
              </div>

              <%!-- Task cards --%>
              <div class="flex-1 overflow-y-auto p-2 space-y-2">
                <%= if tasks == [] do %>
                  <div class="text-center py-6">
                    <p class="text-[11px] text-zinc-600 italic">No tasks</p>
                  </div>
                <% else %>
                  <%= for task <- tasks do %>
                    <div
                      phx-click="kanban_select_task"
                      phx-value-task-id={task.task_id}
                      class="group p-2.5 rounded-lg bg-zinc-900 border border-zinc-800 hover:border-zinc-700 cursor-pointer transition-all duration-150 hover:shadow-md hover:shadow-black/20"
                    >
                      <%!-- Top row: task_id + priority --%>
                      <div class="flex items-center justify-between mb-1.5">
                        <span class="text-[10px] font-mono text-zinc-500"><%= task.task_id %></span>
                        <div class="flex items-center gap-1.5">
                          <%= if task.effort do %>
                            <span class={"text-[9px] font-medium px-1.5 py-0.5 rounded " <> effort_style(task.effort)}>
                              <%= effort_short(task.effort) %>
                            </span>
                          <% end %>
                          <span class="text-sm"><%= priority_emoji(task.priority) %></span>
                        </div>
                      </div>

                      <%!-- Title --%>
                      <p class="text-xs font-medium text-zinc-200 leading-snug mb-1.5 line-clamp-2">
                        <%= task.title %>
                      </p>

                      <%!-- Progress bar (only in_progress) --%>
                      <%= if lane_key == "in_progress" && task.progress_pct > 0 do %>
                        <div class="mb-1.5">
                          <div class="w-full h-1 bg-zinc-800 rounded-full overflow-hidden">
                            <div class="h-full bg-blue-500 rounded-full transition-all" style={"width: #{task.progress_pct}%"}></div>
                          </div>
                          <span class="text-[9px] text-zinc-500"><%= task.progress_pct %>%</span>
                        </div>
                      <% end %>

                      <%!-- Bottom: assigned agent --%>
                      <div class="flex items-center justify-between">
                        <div class="flex items-center gap-1.5">
                          <%= if task.assigned_to do %>
                            <div class="w-4 h-4 rounded bg-zinc-700 flex items-center justify-center">
                              <span class="text-[8px] font-bold text-zinc-400"><%= String.first(task.assigned_to) |> String.upcase() %></span>
                            </div>
                            <span class="text-[10px] text-zinc-500 truncate max-w-[100px]"><%= task.assigned_to %></span>
                          <% else %>
                            <span class="text-[10px] text-zinc-600 italic">Unassigned</span>
                          <% end %>
                        </div>
                        <%= if (task.blocked_by || []) != [] do %>
                          <span class="text-[10px] text-red-400" title="Blocked">🚫</span>
                        <% end %>
                      </div>
                    </div>
                  <% end %>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>
      </div>

      <%!-- Task Detail Modal --%>
      <%= if @kanban_detail_open && @kanban_selected_task do %>
        <div class="fixed inset-0 z-[60] flex items-start justify-end animate-fade-in">
          <div class="absolute inset-0 bg-black/60 backdrop-blur-sm" phx-click="kanban_close_detail"></div>
          <div class="relative w-full max-w-lg h-full bg-zinc-900 border-l border-zinc-800 shadow-2xl overflow-y-auto">
            <% task = @kanban_selected_task %>
            <%!-- Header --%>
            <div class="sticky top-0 z-10 px-5 py-4 border-b border-zinc-800 bg-zinc-900/95 backdrop-blur-sm">
              <div class="flex items-center justify-between">
                <div class="flex items-center gap-2">
                  <span class="text-sm font-mono text-zinc-500"><%= task.task_id %></span>
                  <span class="text-lg"><%= priority_emoji(task.priority) %></span>
                  <.badge variant="outline" class={"text-[10px] " <> lane_badge_style(task.lane)}>
                    <%= String.replace(task.lane, "_", " ") |> String.upcase() %>
                  </.badge>
                </div>
                <div class="flex items-center gap-1">
                  <.button variant="ghost" size="icon" phx-click="kanban_toggle_edit" class="h-7 w-7 text-zinc-500 hover:text-zinc-300">
                    <Icons.pencil class="w-3.5 h-3.5" />
                  </.button>
                  <.button variant="ghost" size="icon" phx-click="kanban_close_detail" class="h-7 w-7 text-zinc-500 hover:text-zinc-300">
                    <Icons.x class="w-4 h-4" />
                  </.button>
                </div>
              </div>
              <h3 class="text-base font-semibold text-zinc-100 mt-2"><%= task.title %></h3>
            </div>

            <div class="px-5 py-4 space-y-5">
              <%!-- Move buttons --%>
              <div>
                <label class="text-[10px] text-zinc-500 uppercase tracking-wider font-medium mb-2 block">Move To</label>
                <div class="flex flex-wrap gap-1.5">
                  <%= for target_lane <- valid_transitions(task.lane) do %>
                    <.button
                      variant="outline"
                      size="sm"
                      phx-click="kanban_move_task"
                      phx-value-task-id={task.task_id}
                      phx-value-lane={target_lane}
                      class={"h-7 text-[11px] " <> lane_move_btn_style(target_lane)}
                    >
                      <%= lane_emoji(target_lane) %> <%= String.replace(target_lane, "_", " ") |> String.capitalize() %>
                    </.button>
                  <% end %>
                </div>
              </div>

              <%!-- Description --%>
              <%= if task.description && task.description != "" do %>
                <div>
                  <label class="text-[10px] text-zinc-500 uppercase tracking-wider font-medium mb-1.5 block">Description</label>
                  <p class="text-sm text-zinc-300 leading-relaxed whitespace-pre-wrap"><%= task.description %></p>
                </div>
              <% end %>

              <%!-- Metadata grid --%>
              <div class="grid grid-cols-2 gap-3">
                <div class="bg-zinc-800/50 rounded-lg p-3">
                  <div class="text-[10px] text-zinc-500 uppercase mb-1">Priority</div>
                  <div class="text-sm text-zinc-200"><%= priority_emoji(task.priority) %> <%= String.capitalize(task.priority) %></div>
                </div>
                <div class="bg-zinc-800/50 rounded-lg p-3">
                  <div class="text-[10px] text-zinc-500 uppercase mb-1">Effort</div>
                  <div class="text-sm text-zinc-200"><%= String.capitalize(task.effort || "—") %></div>
                </div>
                <div class="bg-zinc-800/50 rounded-lg p-3">
                  <div class="text-[10px] text-zinc-500 uppercase mb-1">Assigned To</div>
                  <div class="text-sm text-zinc-200"><%= task.assigned_to || "Unassigned" %></div>
                </div>
                <div class="bg-zinc-800/50 rounded-lg p-3">
                  <div class="text-[10px] text-zinc-500 uppercase mb-1">Created By</div>
                  <div class="text-sm text-zinc-200"><%= task.created_by || "—" %></div>
                </div>
              </div>

              <%!-- Claim button if unassigned --%>
              <%= if is_nil(task.assigned_to) do %>
                <.button variant="outline" size="sm" phx-click="kanban_claim_task" phx-value-task-id={task.task_id}
                  class="w-full h-8 text-xs border-amber-500/30 text-amber-400 hover:bg-amber-500/10">
                  Claim Task
                </.button>
              <% end %>

              <%!-- Progress --%>
              <%= if task.lane == "in_progress" do %>
                <div>
                  <label class="text-[10px] text-zinc-500 uppercase tracking-wider font-medium mb-2 block">Progress</label>
                  <div class="flex items-center gap-3">
                    <input
                      type="range"
                      min="0" max="100" step="5"
                      value={@kanban_progress_pct}
                      phx-change="kanban_update_progress"
                      name="value"
                      class="flex-1 h-2 bg-zinc-800 rounded-lg appearance-none cursor-pointer accent-blue-500"
                    />
                    <span class="text-xs text-zinc-400 font-mono w-10 text-right"><%= @kanban_progress_pct %>%</span>
                    <.button variant="outline" size="sm" phx-click="kanban_save_progress"
                      class="h-7 text-[10px] border-blue-500/30 text-blue-400 hover:bg-blue-500/10">
                      Save
                    </.button>
                  </div>
                  <div class="w-full h-1.5 bg-zinc-800 rounded-full overflow-hidden mt-2">
                    <div class="h-full bg-blue-500 rounded-full transition-all" style={"width: #{@kanban_progress_pct}%"}></div>
                  </div>
                </div>
              <% end %>

              <%!-- Acceptance criteria --%>
              <%= if (task.acceptance_criteria || []) != [] do %>
                <div>
                  <label class="text-[10px] text-zinc-500 uppercase tracking-wider font-medium mb-2 block">Acceptance Criteria</label>
                  <div class="space-y-1">
                    <%= for {criterion, _idx} <- Enum.with_index(task.acceptance_criteria) do %>
                      <div class="flex items-start gap-2 py-1">
                        <span class="text-zinc-600 text-xs mt-0.5">•</span>
                        <span class="text-xs text-zinc-300"><%= criterion %></span>
                      </div>
                    <% end %>
                  </div>
                </div>
              <% end %>

              <%!-- Artifacts --%>
              <%= if @selected_task_artifacts != [] do %>
                <div>
                  <label class="text-[10px] text-zinc-500 uppercase tracking-wider font-medium mb-2 block">📁 Artifacts</label>
                  <div class="space-y-1.5">
                    <%= for artifact <- @selected_task_artifacts do %>
                      <div class="flex items-center gap-2 py-1.5 px-2 rounded-md bg-zinc-800/30">
                        <span class={
                          case artifact.status do
                            "approved" -> "text-green-400 text-xs"
                            "rejected" -> "text-red-400 text-xs"
                            _ -> "text-yellow-400 text-xs"
                          end
                        }>
                          <%= case artifact.status do
                            "approved" -> "✅"
                            "rejected" -> "❌"
                            _ -> "🟡"
                          end %>
                        </span>
                        <div class="flex-1 min-w-0">
                          <div class="flex items-center gap-1.5">
                            <span class="text-xs text-zinc-200 font-medium truncate"><%= artifact.filename %></span>
                            <span class="text-[10px] text-zinc-500">(v<%= artifact.version %>)</span>
                          </div>
                          <div class="text-[10px] text-zinc-500">
                            <%= artifact.status %> · by <%= artifact.created_by || "—" %>
                            <%= if artifact.size do %>
                              · <%= format_file_size(artifact.size) %>
                            <% end %>
                          </div>
                        </div>
                        <.badge variant="outline" class={
                          case artifact.status do
                            "approved" -> "text-[9px] bg-green-500/10 text-green-400 border-green-500/20"
                            "rejected" -> "text-[9px] bg-red-500/10 text-red-400 border-red-500/20"
                            _ -> "text-[9px] bg-yellow-500/10 text-yellow-400 border-yellow-500/20"
                          end
                        }><%= artifact.status %></.badge>
                      </div>
                    <% end %>
                  </div>
                  <div class="mt-2">
                    <.button variant="outline" size="sm" disabled class="h-7 text-[10px] border-zinc-700 text-zinc-600 cursor-not-allowed opacity-50">
                      Upload Artifact (agents only)
                    </.button>
                  </div>
                </div>
              <% end %>

              <%!-- Linked Threads --%>
              <%= if @selected_task_threads != [] do %>
                <div>
                  <label class="text-[10px] text-zinc-500 uppercase tracking-wider font-medium mb-2 block">💬 Discussion (<%= Enum.reduce(@selected_task_threads, 0, fn t, acc -> acc + (t.message_count || 0) end) %> messages)</label>
                  <div class="space-y-1.5">
                    <%= for thread <- @selected_task_threads do %>
                      <div class="flex items-center gap-2 py-1.5 px-2 rounded-md bg-zinc-800/30 cursor-pointer hover:bg-zinc-800/50 transition-colors"
                           phx-click="navigate" phx-value-view="messaging">
                        <span class={"w-1.5 h-1.5 rounded-full shrink-0 " <> if(thread.status == "open", do: "bg-green-400", else: "bg-zinc-600")}></span>
                        <div class="flex-1 min-w-0">
                          <span class="text-xs text-zinc-200 truncate block"><%= thread.subject || "Thread" %></span>
                          <span class="text-[10px] text-zinc-500"><%= thread.message_count || 0 %> messages · <%= thread.status %></span>
                        </div>
                      </div>
                    <% end %>
                  </div>
                </div>
              <% end %>

              <%!-- Tags --%>
              <%= if (task.tags || []) != [] do %>
                <div>
                  <label class="text-[10px] text-zinc-500 uppercase tracking-wider font-medium mb-2 block">Tags</label>
                  <div class="flex flex-wrap gap-1">
                    <%= for tag <- task.tags do %>
                      <.badge variant="outline" class="text-[10px] bg-zinc-800/50 text-zinc-400 border-zinc-700"><%= tag %></.badge>
                    <% end %>
                  </div>
                </div>
              <% end %>

              <%!-- Dependencies --%>
              <%= if (task.depends_on || []) != [] do %>
                <div>
                  <label class="text-[10px] text-zinc-500 uppercase tracking-wider font-medium mb-2 block">Dependencies</label>
                  <div class="flex flex-wrap gap-1">
                    <%= for dep <- task.depends_on do %>
                      <.badge variant="outline" class="text-[10px] bg-zinc-800/50 text-zinc-400 border-zinc-700 font-mono"><%= dep %></.badge>
                    <% end %>
                  </div>
                </div>
              <% end %>

              <%!-- Blocked By --%>
              <%= if (task.blocked_by || []) != [] do %>
                <div>
                  <label class="text-[10px] text-red-500 uppercase tracking-wider font-medium mb-2 block">Blocked By</label>
                  <div class="flex flex-wrap gap-1">
                    <%= for blocker <- task.blocked_by do %>
                      <.badge variant="outline" class="text-[10px] bg-red-500/10 text-red-400 border-red-500/20 font-mono"><%= blocker %></.badge>
                    <% end %>
                  </div>
                </div>
              <% end %>

              <%!-- Timestamps --%>
              <div class="border-t border-zinc-800 pt-4">
                <label class="text-[10px] text-zinc-500 uppercase tracking-wider font-medium mb-2 block">Timeline</label>
                <div class="space-y-1.5 text-xs">
                  <div class="flex justify-between">
                    <span class="text-zinc-500">Created</span>
                    <span class="text-zinc-400 font-mono"><%= format_timestamp(task.inserted_at) %></span>
                  </div>
                  <%= if task.started_at do %>
                    <div class="flex justify-between">
                      <span class="text-zinc-500">Started</span>
                      <span class="text-zinc-400 font-mono"><%= format_timestamp(task.started_at) %></span>
                    </div>
                  <% end %>
                  <%= if task.completed_at do %>
                    <div class="flex justify-between">
                      <span class="text-zinc-500">Completed</span>
                      <span class="text-zinc-400 font-mono"><%= format_timestamp(task.completed_at) %></span>
                    </div>
                  <% end %>
                </div>
              </div>

              <%!-- History --%>
              <%= if @kanban_task_history != [] do %>
                <div class="border-t border-zinc-800 pt-4">
                  <label class="text-[10px] text-zinc-500 uppercase tracking-wider font-medium mb-2 block">History</label>
                  <div class="space-y-2">
                    <%= for entry <- Enum.reverse(@kanban_task_history) do %>
                      <div class="flex items-start gap-2">
                        <div class="w-1.5 h-1.5 rounded-full bg-zinc-600 mt-1.5 shrink-0"></div>
                        <div class="min-w-0">
                          <div class="text-xs text-zinc-300">
                            <span class="font-medium"><%= entry.changed_by %></span>
                            moved
                            <%= if entry.from_lane do %>
                              <span class="text-zinc-500"><%= entry.from_lane %></span> →
                            <% end %>
                            <span class="font-medium"><%= entry.to_lane %></span>
                          </div>
                          <%= if entry.reason do %>
                            <div class="text-[10px] text-zinc-500 italic"><%= entry.reason %></div>
                          <% end %>
                          <div class="text-[10px] text-zinc-600 font-mono"><%= format_timestamp(entry.inserted_at) %></div>
                        </div>
                      </div>
                    <% end %>
                  </div>
                </div>
              <% end %>

              <%!-- Task ID reference --%>
              <div class="text-[10px] text-zinc-600 font-mono pt-2 border-t border-zinc-800">
                ID: <%= task.id %>
              </div>
            </div>
          </div>
        </div>
      <% end %>

      <%!-- Create Task Modal --%>
      <%= if @kanban_create_open do %>
        <div class="fixed inset-0 z-[60] flex items-center justify-center animate-fade-in">
          <div class="absolute inset-0 bg-black/60 backdrop-blur-sm" phx-click="kanban_close_create"></div>
          <div class="relative w-full max-w-lg mx-4 bg-zinc-900 border border-zinc-800 rounded-xl shadow-2xl max-h-[85vh] overflow-y-auto">
            <div class="sticky top-0 z-10 px-6 py-4 border-b border-zinc-800 bg-zinc-900">
              <div class="flex items-center justify-between">
                <h3 class="text-sm font-semibold text-zinc-100">Create Task</h3>
                <.button variant="ghost" size="icon" phx-click="kanban_close_create" class="h-7 w-7 text-zinc-500 hover:text-zinc-300">
                  <Icons.x class="w-4 h-4" />
                </.button>
              </div>
            </div>

            <div class="px-6 py-5 space-y-4">
              <%!-- Title --%>
              <div>
                <label class="text-xs text-zinc-400 mb-1.5 block font-medium">Title <span class="text-red-400">*</span></label>
                <input
                  type="text"
                  phx-keyup="kanban_form_field"
                  phx-value-field="title"
                  value={@kanban_form.title}
                  placeholder="Task title..."
                  autofocus
                  class="w-full h-9 px-3 text-sm bg-zinc-950 border border-zinc-700 rounded-lg text-zinc-100 placeholder:text-zinc-600 focus:border-amber-500/50 focus:outline-none focus:ring-1 focus:ring-amber-500/20"
                />
              </div>

              <%!-- Description --%>
              <div>
                <label class="text-xs text-zinc-400 mb-1.5 block font-medium">Description</label>
                <textarea
                  phx-keyup="kanban_form_field"
                  phx-value-field="description"
                  rows="3"
                  placeholder="Describe the task..."
                  class="w-full px-3 py-2 text-sm bg-zinc-950 border border-zinc-700 rounded-lg text-zinc-100 placeholder:text-zinc-600 focus:border-amber-500/50 focus:outline-none focus:ring-1 focus:ring-amber-500/20 resize-none"
                ><%= @kanban_form.description %></textarea>
              </div>

              <%!-- Priority + Effort row --%>
              <div class="grid grid-cols-2 gap-3">
                <div>
                  <label class="text-xs text-zinc-400 mb-1.5 block font-medium">Priority</label>
                  <select
                    phx-change="kanban_form_field"
                    phx-value-field="priority"
                    name="value"
                    class="w-full h-9 px-3 text-sm bg-zinc-950 border border-zinc-700 rounded-lg text-zinc-100 focus:border-amber-500/50 focus:outline-none"
                  >
                    <option value="critical" selected={@kanban_form.priority == "critical"}>🔴 Critical</option>
                    <option value="high" selected={@kanban_form.priority == "high"}>🟠 High</option>
                    <option value="medium" selected={@kanban_form.priority == "medium"}>🟡 Medium</option>
                    <option value="low" selected={@kanban_form.priority == "low"}>⚪ Low</option>
                  </select>
                </div>
                <div>
                  <label class="text-xs text-zinc-400 mb-1.5 block font-medium">Effort</label>
                  <select
                    phx-change="kanban_form_field"
                    phx-value-field="effort"
                    name="value"
                    class="w-full h-9 px-3 text-sm bg-zinc-950 border border-zinc-700 rounded-lg text-zinc-100 focus:border-amber-500/50 focus:outline-none"
                  >
                    <option value="trivial" selected={@kanban_form.effort == "trivial"}>Trivial</option>
                    <option value="small" selected={@kanban_form.effort == "small"}>Small</option>
                    <option value="medium" selected={@kanban_form.effort == "medium"}>Medium</option>
                    <option value="large" selected={@kanban_form.effort == "large"}>Large</option>
                    <option value="epic" selected={@kanban_form.effort == "epic"}>Epic</option>
                  </select>
                </div>
              </div>

              <%!-- Assigned to --%>
              <div>
                <label class="text-xs text-zinc-400 mb-1.5 block font-medium">Assign To</label>
                <select
                  phx-change="kanban_form_field"
                  phx-value-field="assigned_to"
                  name="value"
                  class="w-full h-9 px-3 text-sm bg-zinc-950 border border-zinc-700 rounded-lg text-zinc-100 focus:border-amber-500/50 focus:outline-none"
                >
                  <option value="">Unassigned</option>
                  <%= for {agent_id, meta} <- Enum.sort_by(@agents, fn {_, m} -> m[:name] || "" end) do %>
                    <option value={agent_id} selected={@kanban_form.assigned_to == agent_id}>
                      <%= meta[:name] || agent_id %>
                    </option>
                  <% end %>
                </select>
              </div>

              <%!-- Squad scope --%>
              <%= if @kanban_squads != [] do %>
                <div>
                  <label class="text-xs text-zinc-400 mb-1.5 block font-medium">Squad</label>
                  <select
                    phx-change="kanban_form_field"
                    phx-value-field="squad_id"
                    name="value"
                    class="w-full h-9 px-3 text-sm bg-zinc-950 border border-zinc-700 rounded-lg text-zinc-100 focus:border-amber-500/50 focus:outline-none"
                  >
                    <option value="">Fleet-wide</option>
                    <%= for squad <- @kanban_squads do %>
                      <option value={squad.id} selected={@kanban_form.squad_id == squad.id}><%= squad.name %></option>
                    <% end %>
                  </select>
                </div>
              <% end %>

              <%!-- Acceptance criteria --%>
              <div>
                <label class="text-xs text-zinc-400 mb-1.5 block font-medium">Acceptance Criteria</label>
                <div class="space-y-1.5 mb-2">
                  <%= for {criterion, idx} <- Enum.with_index(@kanban_form.acceptance_criteria) do %>
                    <div class="flex items-center gap-2 group">
                      <span class="text-zinc-600 text-xs">•</span>
                      <span class="text-xs text-zinc-300 flex-1"><%= criterion %></span>
                      <button phx-click="kanban_remove_criterion" phx-value-index={idx}
                        class="text-zinc-600 hover:text-red-400 opacity-0 group-hover:opacity-100 transition-opacity">
                        <Icons.x class="w-3 h-3" />
                      </button>
                    </div>
                  <% end %>
                </div>
                <div class="flex gap-2">
                  <input
                    type="text"
                    phx-keyup="kanban_form_field"
                    phx-value-field="new_criterion"
                    phx-key="Enter"
                    value={@kanban_form.new_criterion}
                    placeholder="Add criterion..."
                    class="flex-1 h-8 px-3 text-xs bg-zinc-950 border border-zinc-700 rounded-lg text-zinc-100 placeholder:text-zinc-600 focus:border-amber-500/50 focus:outline-none"
                  />
                  <.button variant="outline" size="sm" phx-click="kanban_add_criterion"
                    class="h-8 text-xs border-zinc-700 text-zinc-400 hover:text-zinc-200">
                    <Icons.plus class="w-3 h-3" />
                  </.button>
                </div>
              </div>

              <%!-- Actions --%>
              <div class="flex items-center justify-end gap-2 pt-3 border-t border-zinc-800">
                <.button variant="outline" phx-click="kanban_close_create" class="border-zinc-700 text-zinc-400 hover:text-zinc-200 text-xs">
                  Cancel
                </.button>
                <.button phx-click="kanban_save_task" class="bg-amber-500 hover:bg-amber-400 text-zinc-950 font-semibold text-xs">
                  Create Task
                </.button>
              </div>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # ── Kanban helpers ──

  defp priority_emoji("critical"), do: "🔴"
  defp priority_emoji("high"), do: "🟠"
  defp priority_emoji("medium"), do: "🟡"
  defp priority_emoji("low"), do: "⚪"
  defp priority_emoji(_), do: "⬜"

  defp lane_emoji("backlog"), do: "📋"
  defp lane_emoji("ready"), do: "🟢"
  defp lane_emoji("in_progress"), do: "🔵"
  defp lane_emoji("review"), do: "🟡"
  defp lane_emoji("done"), do: "✅"
  defp lane_emoji("cancelled"), do: "🚫"
  defp lane_emoji(_), do: "⬜"

  defp effort_short("trivial"), do: "XS"
  defp effort_short("small"), do: "S"
  defp effort_short("medium"), do: "M"
  defp effort_short("large"), do: "L"
  defp effort_short("epic"), do: "XL"
  defp effort_short(_), do: "?"

  defp effort_style("trivial"), do: "bg-zinc-800 text-zinc-500"
  defp effort_style("small"), do: "bg-green-500/10 text-green-400"
  defp effort_style("medium"), do: "bg-yellow-500/10 text-yellow-400"
  defp effort_style("large"), do: "bg-orange-500/10 text-orange-400"
  defp effort_style("epic"), do: "bg-red-500/10 text-red-400"
  defp effort_style(_), do: "bg-zinc-800 text-zinc-500"

  defp format_file_size(nil), do: "—"
  defp format_file_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_file_size(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_file_size(bytes), do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"

  defp lane_badge_style("backlog"), do: "bg-zinc-800/50 text-zinc-400 border-zinc-700"
  defp lane_badge_style("ready"), do: "bg-green-500/10 text-green-400 border-green-500/20"
  defp lane_badge_style("in_progress"), do: "bg-blue-500/10 text-blue-400 border-blue-500/20"
  defp lane_badge_style("review"), do: "bg-yellow-500/10 text-yellow-400 border-yellow-500/20"
  defp lane_badge_style("done"), do: "bg-emerald-500/10 text-emerald-400 border-emerald-500/20"
  defp lane_badge_style("cancelled"), do: "bg-red-500/10 text-red-400 border-red-500/20"
  defp lane_badge_style(_), do: "bg-zinc-800 text-zinc-400 border-zinc-700"

  defp lane_move_btn_style("ready"), do: "border-green-500/30 text-green-400 hover:bg-green-500/10"
  defp lane_move_btn_style("in_progress"), do: "border-blue-500/30 text-blue-400 hover:bg-blue-500/10"
  defp lane_move_btn_style("review"), do: "border-yellow-500/30 text-yellow-400 hover:bg-yellow-500/10"
  defp lane_move_btn_style("done"), do: "border-emerald-500/30 text-emerald-400 hover:bg-emerald-500/10"
  defp lane_move_btn_style("backlog"), do: "border-zinc-600 text-zinc-400 hover:bg-zinc-800"
  defp lane_move_btn_style("cancelled"), do: "border-red-500/30 text-red-400 hover:bg-red-500/10"
  defp lane_move_btn_style(_), do: "border-zinc-700 text-zinc-400"

  defp valid_transitions("backlog"), do: ~w(ready cancelled)
  defp valid_transitions("ready"), do: ~w(in_progress cancelled)
  defp valid_transitions("in_progress"), do: ~w(review ready cancelled)
  defp valid_transitions("review"), do: ~w(done in_progress cancelled)
  defp valid_transitions("done"), do: ~w(cancelled)
  defp valid_transitions("cancelled"), do: ~w(backlog)
  defp valid_transitions(_), do: []

  defp format_timestamp(nil), do: "—"
  defp format_timestamp(%NaiveDateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  end
  defp format_timestamp(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  end
  defp format_timestamp(_), do: "—"

  # ══════════════════════════════════════════════════════════
  # Page: Messaging
  # ══════════════════════════════════════════════════════════

  defp render_messaging(assigns) do
    agents_sorted = assigns.agents
      |> Enum.sort_by(fn {_, m} -> Components.state_sort_order(m[:state]) end)

    # Build tier map from registered_agents_detail
    tier_map = Map.new(assigns.registered_agents_detail, fn a ->
      {a.agent_id, tier_for_agent(a)}
    end)

    assigns = assign(assigns, agents_sorted: agents_sorted, tier_map: tier_map)

    ~H"""
    <div class="h-full flex flex-col animate-fade-in">
      <%!-- Tabs --%>
      <div class="px-4 pt-3 pb-0 border-b border-zinc-800 shrink-0">
        <div class="flex gap-1">
          <%= for {tab, label, icon} <- [{"dms", "DMs", :message_square}, {"threads", "Threads", :layers}, {"escalations", "Escalations", :alert_triangle}, {"announcements", "Announcements", :radio}] do %>
            <button phx-click="switch_messaging_tab" phx-value-tab={tab}
              class={"px-3 py-2 text-xs font-medium rounded-t-lg transition-colors " <>
                if(@messaging_tab == tab,
                  do: "bg-zinc-800 text-amber-400 border-b-2 border-amber-500",
                  else: "text-zinc-500 hover:text-zinc-300 hover:bg-zinc-800/50")}>
              <%= label %>
            </button>
          <% end %>
        </div>
      </div>

      <%!-- Tab content --%>
      <div class="flex-1 overflow-hidden">
        <%= case @messaging_tab do %>
          <% "dms" -> %>
            <%!-- DMs tab — upgraded --%>
            <div class="h-full flex">
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
                          <div class="flex items-center gap-1.5">
                            <span class="text-sm text-zinc-200 truncate"><%= m[:name] || id %></span>
                            <% agent_tier = Map.get(@tier_map, id) %>
                            <%= if agent_tier do %>
                              <span class={"text-[9px] px-1 py-0.5 rounded font-bold border " <> tier_badge_class(agent_tier)}>T<%= agent_tier %></span>
                            <% end %>
                          </div>
                          <div class="text-[10px] text-zinc-600"><%= m[:state] %></div>
                        </div>
                        <%!-- Unread dot --%>
                        <span class="w-2 h-2 rounded-full bg-amber-500 opacity-0"></span>
                      </button>
                    <% end %>
                  <% end %>
                </div>
              </div>

              <%!-- Conversation --%>
              <div class="flex-1 flex flex-col min-w-0">
                <%= if @msg_to do %>
                  <% am = Map.get(@agents, @msg_to, %{name: @msg_to}) %>
                  <% target_tier = Map.get(@tier_map, @msg_to) %>
                  <div class="px-4 py-3 border-b border-zinc-800 shrink-0 flex items-center gap-2.5">
                    <div class={"w-7 h-7 rounded-lg flex items-center justify-center text-xs font-bold " <> Components.avatar_bg(am[:state])}>
                      <%= Components.avatar_initial(am[:name] || @msg_to) %>
                    </div>
                    <div>
                      <div class="flex items-center gap-2">
                        <span class="text-sm font-medium text-zinc-200"><%= am[:name] || @msg_to %></span>
                        <%= if target_tier do %>
                          <span class={"text-[9px] px-1.5 py-0.5 rounded font-bold border " <> tier_badge_class(target_tier)}>Tier <%= target_tier %></span>
                        <% end %>
                      </div>
                      <div class="text-[10px] text-zinc-500"><%= am[:state] || "offline" %></div>
                    </div>
                  </div>

                  <%!-- Access control denial banner --%>
                  <%= if @msg_access_result do %>
                    <div class="mx-4 mt-2 p-3 rounded-lg bg-red-500/10 border border-red-500/20">
                      <div class="flex items-start gap-2">
                        <Icons.shield class="w-4 h-4 text-red-400 shrink-0 mt-0.5" />
                        <div class="flex-1">
                          <div class="text-xs font-medium text-red-400">Access Denied</div>
                          <div class="text-xs text-red-300/70 mt-0.5"><%= elem(@msg_access_result, 0) %></div>
                          <% suggestion = elem(@msg_access_result, 1) %>
                          <%= if suggestion[:suggestion] do %>
                            <div class="text-[10px] text-zinc-400 mt-1">💡 <%= suggestion[:suggestion] || suggestion["suggestion"] %></div>
                          <% end %>
                          <button phx-click="escalate_from_dm" phx-value-target={@msg_to}
                            class="mt-2 text-[10px] px-2.5 py-1 rounded bg-amber-500/15 text-amber-400 hover:bg-amber-500/25 transition-colors">
                            ↗ Escalate
                          </button>
                        </div>
                      </div>
                    </div>
                  <% end %>

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

          <% "threads" -> %>
            <%!-- Threads tab --%>
            <div class="h-full flex">
              <%!-- Thread list --%>
              <div class="w-72 border-r border-zinc-800 overflow-y-auto shrink-0 bg-zinc-900">
                <div class="p-3">
                  <div class="flex items-center justify-between px-2 py-2">
                    <span class="text-[10px] font-semibold text-zinc-500 uppercase tracking-wider">Threads</span>
                    <button phx-click={JS.toggle(to: "#new-thread-form")}
                      class="text-[10px] px-2 py-1 rounded bg-amber-500/15 text-amber-400 hover:bg-amber-500/25">
                      + New Thread
                    </button>
                  </div>

                  <%!-- New thread form (hidden by default) --%>
                  <div id="new-thread-form" class="hidden px-2 pb-3">
                    <form phx-submit="create_thread" class="space-y-2">
                      <input type="text" name="subject" placeholder="Subject..." required
                        class="w-full h-8 px-2 text-xs bg-zinc-800 border border-zinc-700 rounded text-zinc-200 focus:border-amber-500/50" />
                      <select name="scope" class="w-full h-8 px-2 text-xs bg-zinc-800 border border-zinc-700 rounded text-zinc-200">
                        <option value="dm">DM</option>
                        <option value="squad">Squad</option>
                        <option value="task">Task</option>
                      </select>
                      <.button type="submit" class="w-full bg-amber-500 hover:bg-amber-400 text-zinc-950 font-semibold text-xs h-8">
                        Create Thread
                      </.button>
                    </form>
                  </div>

                  <%= if @threads == [] do %>
                    <p class="px-2 py-3 text-xs text-zinc-600">No open threads</p>
                  <% else %>
                    <%= for thread <- @threads do %>
                      <button phx-click="select_thread" phx-value-thread-id={thread.thread_id}
                        class={"w-full text-left px-3 py-2.5 rounded-lg transition-colors mb-1 " <>
                          if(@selected_thread == thread.thread_id, do: "bg-zinc-800", else: "hover:bg-zinc-800/50")}>
                        <div class="flex items-center gap-2 mb-1">
                          <span class="text-sm text-zinc-200 truncate flex-1"><%= thread.subject %></span>
                          <span class={"text-[9px] px-1.5 py-0.5 rounded font-medium " <>
                            case thread.scope do
                              "dm" -> "bg-blue-500/15 text-blue-400"
                              "squad" -> "bg-green-500/15 text-green-400"
                              "task" -> "bg-purple-500/15 text-purple-400"
                              _ -> "bg-zinc-700 text-zinc-400"
                            end}><%= thread.scope %></span>
                        </div>
                        <div class="flex items-center gap-3 text-[10px] text-zinc-500">
                          <span><%= length(thread.participant_ids) %> participants</span>
                          <span><%= thread.message_count %> msgs</span>
                          <span class={"font-medium " <> if(thread.status == "open", do: "text-emerald-400", else: "text-zinc-600")}><%= thread.status %></span>
                        </div>
                        <%= if thread.task_id do %>
                          <div class="mt-1">
                            <span class="text-[9px] px-1.5 py-0.5 rounded bg-purple-500/10 text-purple-400 border border-purple-500/20">
                              T-<%= String.slice(thread.task_id, 0..7) %>
                            </span>
                          </div>
                        <% end %>
                      </button>
                    <% end %>
                  <% end %>
                </div>
              </div>

              <%!-- Thread messages --%>
              <div class="flex-1 flex flex-col min-w-0">
                <%= if @selected_thread do %>
                  <div class="px-4 py-3 border-b border-zinc-800 shrink-0 flex items-center justify-between">
                    <div>
                      <% sel_thread = Enum.find(@threads, fn t -> t.thread_id == @selected_thread end) %>
                      <div class="text-sm font-medium text-zinc-200"><%= if sel_thread, do: sel_thread.subject, else: @selected_thread %></div>
                      <div class="text-[10px] text-zinc-500"><%= @selected_thread %></div>
                    </div>
                    <button phx-click="close_thread" phx-value-thread-id={@selected_thread}
                      data-confirm="Close this thread?"
                      class="text-[10px] px-2.5 py-1 rounded border border-zinc-700 text-zinc-400 hover:text-red-400 hover:border-red-500/30">
                      Close Thread
                    </button>
                  </div>

                  <div class="flex-1 overflow-y-auto px-4 py-4" id="thread-msgs" phx-hook="ScrollBottom">
                    <%= if @thread_messages == [] do %>
                      <div class="flex flex-col items-center justify-center h-full text-center">
                        <p class="text-sm text-zinc-500">No messages in thread</p>
                      </div>
                    <% else %>
                      <%= for msg <- @thread_messages do %>
                        <div class="mb-3">
                          <div class="flex items-center gap-2 mb-0.5">
                            <span class="text-xs font-medium text-zinc-300"><%= msg["from"] %></span>
                            <span class="text-[10px] text-zinc-600"><%= msg["timestamp"] %></span>
                          </div>
                          <div class="text-sm text-zinc-400 pl-0"><%= msg["body"] %></div>
                        </div>
                      <% end %>
                    <% end %>
                  </div>

                  <div class="px-4 py-3 border-t border-zinc-800 shrink-0">
                    <form phx-submit="send_thread_message" class="flex gap-2">
                      <.input type="text" name="body" value="" placeholder="Reply to thread..." autocomplete="off"
                        class="flex-1 bg-zinc-900 border-zinc-800 text-zinc-100 placeholder:text-zinc-600" />
                      <.button type="submit" class="bg-amber-500 hover:bg-amber-400 text-zinc-950 font-semibold text-xs shrink-0">
                        <Icons.send class="w-3.5 h-3.5 mr-1" /> Reply
                      </.button>
                    </form>
                  </div>
                <% else %>
                  <div class="flex-1 flex items-center justify-center">
                    <div class="text-center">
                      <Icons.layers class="w-6 h-6 text-zinc-600 mx-auto mb-3" />
                      <p class="font-medium text-zinc-400">Select a thread</p>
                      <p class="text-sm text-zinc-500 mt-1">Or create a new one</p>
                    </div>
                  </div>
                <% end %>
              </div>
            </div>

          <% "escalations" -> %>
            <%!-- Escalations tab --%>
            <div class="h-full overflow-y-auto p-4">
              <div class="max-w-3xl mx-auto">
                <%= if @escalations == [] do %>
                  <div class="flex flex-col items-center justify-center py-16">
                    <Icons.shield class="w-8 h-8 text-zinc-600 mb-3" />
                    <p class="text-sm text-zinc-500">No pending escalations</p>
                  </div>
                <% else %>
                  <div class="space-y-3">
                    <%= for esc <- @escalations do %>
                      <div class="p-4 rounded-lg bg-zinc-900 border border-zinc-800">
                        <div class="flex items-start justify-between mb-2">
                          <div>
                            <div class="flex items-center gap-2">
                              <span class="text-sm font-medium text-zinc-200"><%= esc.subject || "Escalation" %></span>
                              <span class={"text-[9px] px-1.5 py-0.5 rounded font-bold " <>
                                case esc.priority do
                                  "critical" -> "bg-red-500/15 text-red-400"
                                  "high" -> "bg-orange-500/15 text-orange-400"
                                  "normal" -> "bg-blue-500/15 text-blue-400"
                                  _ -> "bg-zinc-700 text-zinc-400"
                                end}><%= esc.priority %></span>
                            </div>
                            <div class="text-[10px] text-zinc-500 mt-0.5">
                              From: <span class="text-zinc-400"><%= esc.from_agent %></span>
                              → Target role: <span class="text-zinc-400"><%= esc.target_role %></span>
                            </div>
                          </div>
                          <span class="text-[10px] text-zinc-600"><%= esc.created_at %></span>
                        </div>

                        <div class="text-xs text-zinc-400 mb-3 p-2 rounded bg-zinc-800/50"><%= esc.body %></div>

                        <%!-- Action buttons --%>
                        <%= if @escalation_action_id == esc.id do %>
                          <%= case @escalation_action do %>
                            <% "forward" -> %>
                              <div class="space-y-2 p-2 rounded bg-zinc-800/30 border border-zinc-700/50">
                                <div class="text-[10px] font-medium text-zinc-400">Forward to agent:</div>
                                <select phx-change="escalation_forward_select" name="agent"
                                  class="w-full h-8 px-2 text-xs bg-zinc-800 border border-zinc-700 rounded text-zinc-200">
                                  <option value="">Select agent...</option>
                                  <%= for {id, m} <- @agents do %>
                                    <option value={id} selected={@escalation_forward_to == id}><%= m[:name] || id %></option>
                                  <% end %>
                                </select>
                                <div class="flex gap-2">
                                  <.button phx-click="submit_escalation_forward" class="text-xs bg-amber-500 hover:bg-amber-400 text-zinc-950 h-7">Forward</.button>
                                  <.button phx-click="cancel_escalation_action" variant="outline" class="text-xs border-zinc-700 text-zinc-400 h-7">Cancel</.button>
                                </div>
                              </div>
                            <% "handle" -> %>
                              <form phx-submit="submit_escalation_handle" class="space-y-2 p-2 rounded bg-zinc-800/30 border border-zinc-700/50">
                                <div class="text-[10px] font-medium text-zinc-400">Response:</div>
                                <textarea name="response" rows="3" placeholder="Your response..."
                                  class="w-full px-2 py-1.5 text-xs bg-zinc-800 border border-zinc-700 rounded text-zinc-200 resize-none"></textarea>
                                <div class="flex gap-2">
                                  <.button type="submit" class="text-xs bg-emerald-500 hover:bg-emerald-400 text-zinc-950 h-7">Submit</.button>
                                  <.button type="button" phx-click="cancel_escalation_action" variant="outline" class="text-xs border-zinc-700 text-zinc-400 h-7">Cancel</.button>
                                </div>
                              </form>
                            <% "reject" -> %>
                              <form phx-submit="submit_escalation_reject" class="space-y-2 p-2 rounded bg-zinc-800/30 border border-zinc-700/50">
                                <div class="text-[10px] font-medium text-zinc-400">Rejection reason:</div>
                                <textarea name="reason" rows="2" placeholder="Reason for rejection..."
                                  class="w-full px-2 py-1.5 text-xs bg-zinc-800 border border-zinc-700 rounded text-zinc-200 resize-none"></textarea>
                                <div class="flex gap-2">
                                  <.button type="submit" class="text-xs bg-red-500 hover:bg-red-400 text-white h-7">Reject</.button>
                                  <.button type="button" phx-click="cancel_escalation_action" variant="outline" class="text-xs border-zinc-700 text-zinc-400 h-7">Cancel</.button>
                                </div>
                              </form>
                            <% _ -> %>
                          <% end %>
                        <% else %>
                          <div class="flex gap-2">
                            <button phx-click="escalation_action" phx-value-action="forward" phx-value-id={esc.id}
                              class="text-[10px] px-2.5 py-1 rounded bg-blue-500/15 text-blue-400 hover:bg-blue-500/25">
                              ↗ Forward
                            </button>
                            <button phx-click="escalation_action" phx-value-action="handle" phx-value-id={esc.id}
                              class="text-[10px] px-2.5 py-1 rounded bg-emerald-500/15 text-emerald-400 hover:bg-emerald-500/25">
                              ✓ Handle
                            </button>
                            <button phx-click="escalation_action" phx-value-action="reject" phx-value-id={esc.id}
                              class="text-[10px] px-2.5 py-1 rounded bg-red-500/15 text-red-400 hover:bg-red-500/25">
                              ✕ Reject
                            </button>
                          </div>

                          <%!-- Status history --%>
                          <%= if esc.status != "pending" do %>
                            <div class="mt-2 text-[10px] text-zinc-500">
                              Status: <span class={"font-medium " <>
                                case esc.status do
                                  "forwarded" -> "text-blue-400"
                                  "handled" -> "text-emerald-400"
                                  "rejected" -> "text-red-400"
                                  _ -> "text-zinc-400"
                                end}><%= esc.status %></span>
                              <%= if esc.forwarded_to do %>
                                → <span class="text-zinc-400"><%= esc.forwarded_to %></span>
                              <% end %>
                            </div>
                          <% end %>
                        <% end %>
                      </div>
                    <% end %>
                  </div>
                <% end %>
              </div>
            </div>

          <% "announcements" -> %>
            <%!-- Announcements tab --%>
            <div class="h-full overflow-y-auto p-4">
              <div class="max-w-3xl mx-auto">
                <%!-- New announcement form (tier 0-1 only — dashboard user is effectively tier 0) --%>
                <div class="mb-4 p-4 rounded-lg bg-zinc-900 border border-zinc-800">
                  <div class="text-xs font-semibold text-zinc-400 mb-3">📢 New Announcement</div>
                  <form phx-submit="send_announcement" class="space-y-2">
                    <div class="flex gap-2">
                      <select name="scope" class="h-8 px-2 text-xs bg-zinc-800 border border-zinc-700 rounded text-zinc-200">
                        <option value="fleet">Fleet-wide</option>
                        <option value="squad">Squad</option>
                      </select>
                      <select name="priority" class="h-8 px-2 text-xs bg-zinc-800 border border-zinc-700 rounded text-zinc-200">
                        <option value="normal">Normal</option>
                        <option value="high">High</option>
                        <option value="urgent">Urgent</option>
                      </select>
                    </div>
                    <textarea name="body" rows="3" placeholder="Announcement body..."
                      class="w-full px-2 py-1.5 text-xs bg-zinc-800 border border-zinc-700 rounded text-zinc-200 resize-none"></textarea>
                    <.button type="submit" class="bg-amber-500 hover:bg-amber-400 text-zinc-950 font-semibold text-xs h-8">
                      <Icons.radio class="w-3.5 h-3.5 mr-1" /> Broadcast
                    </.button>
                  </form>
                </div>

                <%!-- Announcement history --%>
                <div class="text-[10px] font-semibold text-zinc-500 uppercase tracking-wider mb-2">Recent Announcements</div>
                <%= if @announcements == [] do %>
                  <div class="flex flex-col items-center justify-center py-12">
                    <Icons.radio class="w-8 h-8 text-zinc-600 mb-3" />
                    <p class="text-sm text-zinc-500">No announcements yet</p>
                  </div>
                <% else %>
                  <div class="space-y-2">
                    <%= for ann <- @announcements do %>
                      <div class="p-3 rounded-lg bg-zinc-900 border border-zinc-800">
                        <div class="flex items-center justify-between mb-1">
                          <div class="flex items-center gap-2">
                            <span class="text-xs font-medium text-zinc-300"><%= ann["from"] %></span>
                            <span class={"text-[9px] px-1.5 py-0.5 rounded " <>
                              case ann["scope"] do
                                "fleet" -> "bg-amber-500/15 text-amber-400"
                                s when is_binary(s) -> "bg-green-500/15 text-green-400"
                                _ -> "bg-zinc-700 text-zinc-400"
                              end}><%= ann["scope"] %></span>
                            <%= if ann["priority"] != "normal" do %>
                              <span class={"text-[9px] px-1.5 py-0.5 rounded font-bold " <>
                                case ann["priority"] do
                                  "urgent" -> "bg-red-500/15 text-red-400"
                                  "high" -> "bg-orange-500/15 text-orange-400"
                                  _ -> "bg-zinc-700 text-zinc-400"
                                end}><%= ann["priority"] %></span>
                            <% end %>
                          </div>
                          <span class="text-[10px] text-zinc-600"><%= ann["timestamp"] %></span>
                        </div>
                        <div class="text-xs text-zinc-400"><%= ann["body"] %></div>
                      </div>
                    <% end %>
                  </div>
                <% end %>
              </div>
            </div>

          <% _ -> %>
            <div class="p-4 text-zinc-500">Unknown tab</div>
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
      <div class="w-full">
        <div class="mb-6">
          <h2 class="text-lg font-semibold text-zinc-100">Settings</h2>
          <p class="text-sm text-zinc-500">Fleet configuration and API key management</p>
        </div>

      <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">

        <%!-- LEFT COLUMN --%>
        <div class="space-y-4">

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
                  <label class="text-[11px] text-zinc-400 mb-1 block font-medium">Confirm Admin API Key</label>
                  <.input
                    type="password"
                    name="admin_key"
                    placeholder="rf_admin_..."
                    autocomplete="off"
                    required
                    class="w-full bg-zinc-950 border-zinc-700 text-zinc-100 placeholder:text-zinc-600 focus:border-amber-500/50 h-9 text-xs"
                  />
                  <p class="text-[10px] text-zinc-600 mt-1">Required to verify ownership</p>
                </div>
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
            <div class="flex items-center justify-between">
              <div>
                <.card_title class="text-sm font-medium text-zinc-300">API Keys</.card_title>
                <.card_description>Manage keys for agent connections and admin access</.card_description>
              </div>
            </div>
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

            <%!-- Active keys table --%>
            <div class="mb-4">
              <div class="text-[10px] text-zinc-500 uppercase tracking-wider mb-2 font-medium">Active Keys</div>
              <%= if Enum.empty?(@active_keys) do %>
                <div class="text-xs text-zinc-600 py-3 text-center">No active keys</div>
              <% else %>
                <div class="space-y-1">
                  <%= for key <- @active_keys do %>
                    <div class="flex items-center justify-between py-2 px-3 rounded-lg bg-zinc-800/30 hover:bg-zinc-800/50 transition-colors group">
                      <div class="flex items-center gap-3 min-w-0">
                        <div class={"w-2 h-2 rounded-full flex-shrink-0 " <> key_color(key.type)}></div>
                        <div class="min-w-0">
                          <div class="flex items-center gap-2">
                            <span class="text-xs font-medium text-zinc-200 capitalize"><%= key.type %></span>
                            <code class="text-[10px] text-zinc-500 font-mono"><%= key.key_prefix %>•••</code>
                          </div>
                          <div class="text-[10px] text-zinc-600">
                            Created <%= format_date(key.inserted_at) %>
                          </div>
                        </div>
                      </div>
                      <button
                        phx-click="revoke_key"
                        phx-value-id={key.id}
                        data-confirm={"Revoke this #{key.type} key? This cannot be undone."}
                        class="text-[10px] text-zinc-600 hover:text-red-400 opacity-0 group-hover:opacity-100 transition-all px-2 py-1 rounded border border-transparent hover:border-red-500/20"
                      >
                        Revoke
                      </button>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>

            <%!-- Generate new keys --%>
            <div>
              <div class="text-[10px] text-zinc-500 uppercase tracking-wider mb-2 font-medium">Generate New Key</div>
              <div class="space-y-1.5">
                <%= for {type, desc, icon} <- [{"live", "For agent WebSocket connections", :zap}, {"test", "For testing & development", :code}, {"admin", "For dashboard & admin API", :settings}] do %>
                  <% has_key = Enum.any?(@active_keys, &(&1.type == type)) %>
                  <div class="flex items-center justify-between py-2 px-3 rounded-lg hover:bg-zinc-800/50 transition-colors">
                    <div class="flex items-center gap-3">
                      <div class={"w-2 h-2 rounded-full " <> key_color(type)}></div>
                      <div>
                        <div class="text-xs font-medium text-zinc-200 capitalize"><%= type %></div>
                        <div class="text-[10px] text-zinc-600"><%= desc %></div>
                      </div>
                    </div>
                    <.button
                      variant="outline"
                      size="sm"
                      phx-click="generate_key"
                      phx-value-type={type}
                      class={"h-7 text-[10px] border-zinc-700 " <> if(has_key, do: "text-zinc-500 hover:text-zinc-300", else: "text-amber-400 border-amber-500/30 hover:bg-amber-500/10")}
                    >
                      <%= if has_key, do: "Add Another", else: "Generate" %>
                    </.button>
                  </div>
                <% end %>
              </div>
            </div>
          </.card_content>
        </.card>

        </div><%!-- end LEFT COLUMN --%>

        <%!-- RIGHT COLUMN --%>
        <div class="space-y-4">

        <%!-- Connect Agents Guide --%>
        <.card class="bg-zinc-900 border-zinc-800 mb-4">
          <.card_header class="pb-2">
            <.card_title class="text-sm font-medium text-zinc-300">Connect Agents</.card_title>
            <.card_description>Use a live API key to connect agents to your fleet</.card_description>
          </.card_header>
          <.card_content>
            <div class="space-y-3">
              <div>
                <div class="text-[10px] text-zinc-500 uppercase tracking-wider mb-1.5 font-medium">OpenClaw Plugin</div>
                <div class="bg-zinc-950 rounded-lg p-3 text-[11px] font-mono text-zinc-300 overflow-x-auto">
                  <div class="text-zinc-600"># Add to your openclaw.yaml</div>
                  <div><span class="text-amber-400">ringforge</span>:</div>
                  <div class="pl-4"><span class="text-zinc-500">enabled</span>: <span class="text-green-400">true</span></div>
                  <div class="pl-4"><span class="text-zinc-500">server</span>: <span class="text-cyan-400">"wss://ringforge.wejoona.com"</span></div>
                  <div class="pl-4"><span class="text-zinc-500">apiKey</span>: <span class="text-cyan-400">"YOUR_LIVE_KEY"</span></div>
                  <div class="pl-4"><span class="text-zinc-500">fleetId</span>: <span class="text-cyan-400">"<%= @fleet_id %>"</span></div>
                  <div class="pl-4"><span class="text-zinc-500">agentName</span>: <span class="text-cyan-400">"My Agent"</span></div>
                  <div class="pl-4"><span class="text-zinc-500">capabilities</span>: <span class="text-cyan-400">["code", "research"]</span></div>
                </div>
              </div>
              <div>
                <div class="text-[10px] text-zinc-500 uppercase tracking-wider mb-1.5 font-medium">WebSocket Direct</div>
                <div class="bg-zinc-950 rounded-lg p-3 text-[11px] font-mono text-zinc-300 overflow-x-auto">
                  <div class="text-zinc-600"># Connect to</div>
                  <div>wss://ringforge.wejoona.com/ws</div>
                  <div class="text-zinc-600 mt-1"># Auth params</div>
                  <div class="text-zinc-500">api_key: <span class="text-cyan-400">YOUR_LIVE_KEY</span></div>
                  <div class="text-zinc-500">agent: <span class="text-cyan-400"><%= ~s|{"name": "...", "capabilities": [...]}| %></span></div>
                </div>
              </div>
              <% live_keys = Enum.filter(@active_keys, &(&1.type == "live")) %>
              <%= if Enum.empty?(live_keys) do %>
                <div class="flex items-center gap-2 text-xs text-amber-400 bg-amber-500/10 border border-amber-500/20 rounded-lg py-2.5 px-3">
                  <Icons.alert_triangle class="w-4 h-4 flex-shrink-0" />
                  <span>No live key yet — generate one above to connect agents</span>
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

        </div><%!-- end RIGHT COLUMN --%>
      </div><%!-- end grid --%>

        <%!-- Full-width cards below the grid --%>
        <div class="mt-4 grid grid-cols-1 lg:grid-cols-2 gap-4">
          <%!-- Theme --%>
          <.card class="bg-zinc-900 border-zinc-800">
            <.card_header class="pb-2">
              <.card_title class="text-sm font-medium text-zinc-300">Appearance</.card_title>
              <.card_description>Customize the dashboard theme</.card_description>
            </.card_header>
            <.card_content>
              <div class="flex items-center gap-2">
                <%= for {mode, label, icon_svg} <- [
                  {"light", "Light", ~s(<svg xmlns="http://www.w3.org/2000/svg" class="w-4 h-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="5"/><line x1="12" y1="1" x2="12" y2="3"/><line x1="12" y1="21" x2="12" y2="23"/><line x1="4.22" y1="4.22" x2="5.64" y2="5.64"/><line x1="18.36" y1="18.36" x2="19.78" y2="19.78"/><line x1="1" y1="12" x2="3" y2="12"/><line x1="21" y1="12" x2="23" y2="12"/><line x1="4.22" y1="19.78" x2="5.64" y2="18.36"/><line x1="18.36" y1="5.64" x2="19.78" y2="4.22"/></svg>)},
                  {"dark", "Dark", ~s(<svg xmlns="http://www.w3.org/2000/svg" class="w-4 h-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"/></svg>)},
                  {"system", "System", ~s(<svg xmlns="http://www.w3.org/2000/svg" class="w-4 h-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="2" y="3" width="20" height="14" rx="2" ry="2"/><line x1="8" y1="21" x2="16" y2="21"/><line x1="12" y1="17" x2="12" y2="21"/></svg>)}
                ] do %>
                  <button
                    phx-click="set_theme"
                    phx-value-theme={mode}
                    class={"flex items-center gap-2 px-4 py-2.5 rounded-lg border text-xs font-medium transition-all " <>
                      if(@theme == mode,
                        do: "bg-amber-500/15 border-amber-500/40 text-amber-400",
                        else: "bg-zinc-800/50 border-zinc-700 text-zinc-400 hover:text-zinc-200 hover:border-zinc-600"
                      )}
                  >
                    <%= Phoenix.HTML.raw(icon_svg) %>
                    <%= label %>
                  </button>
                <% end %>
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
    </div>
    """
  end

  # ══════════════════════════════════════════════════════════
  # Authentication
  # ══════════════════════════════════════════════════════════

  defp authenticate(_params, session) do
    # Only session-based auth — no API key in URL params (security: prevents key leaking in
    # browser history, server logs, referrer headers). Use the API Key tab form instead.
    case session["tenant_id"] do
      nil -> {:error, :unauthenticated}
      tenant_id ->
        fleet = load_default_fleet(tenant_id)
        tenant = Hub.Repo.get(Hub.Auth.Tenant, tenant_id)
        plan = if(tenant, do: tenant.plan || "free", else: "free")
        email = if(tenant, do: tenant.email, else: nil)
        if fleet, do: {:ok, tenant_id, fleet.id, fleet.name, plan, email}, else: {:error, :unauthenticated}
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

  defp load_active_keys(tenant_id) do
    import Ecto.Query
    from(k in Hub.Auth.ApiKey,
      where: k.tenant_id == ^tenant_id and is_nil(k.revoked_at),
      order_by: [asc: k.type, desc: k.inserted_at]
    ) |> Hub.Repo.all()
  end

  defp key_color("live"), do: "bg-green-400"
  defp key_color("test"), do: "bg-blue-400"
  defp key_color("admin"), do: "bg-amber-400"
  defp key_color(_), do: "bg-zinc-400"

  defp format_date(%NaiveDateTime{} = dt) do
    Calendar.strftime(dt, "%b %d, %Y %H:%M")
  end
  defp format_date(%DateTime{} = dt) do
    Calendar.strftime(dt, "%b %d, %Y %H:%M")
  end
  defp format_date(_), do: "—"

  defp load_registered_agents(tenant_id) do
    import Ecto.Query
    from(a in Hub.Auth.Agent,
      where: a.tenant_id == ^tenant_id,
      order_by: [desc: a.inserted_at],
      preload: [:fleet]
    ) |> Hub.Repo.all()
  end

  defp load_squads_for_fleet(fleet_id) do
    try do
      Hub.Fleets.list_squads(fleet_id)
    rescue
      _ -> []
    end
  end

  defp load_squad_memory(squad_id) do
    case Hub.SquadMemory.list(squad_id, limit: 100) do
      {:ok, entries} -> entries
      _ -> []
    end
  rescue
    _ -> []
  end

  defp filter_squad_activity(activities, members) do
    member_ids = MapSet.new(Enum.map(members, & &1.agent_id))
    activities
    |> Enum.filter(fn act ->
      agent_id = Map.get(act, :agent_id) || Map.get(act, "agent_id")
      agent_id && MapSet.member?(member_ids, agent_id)
    end)
    |> Enum.take(50)
  end

  defp get_squad_leader(squad, members) do
    # First check settings for explicit leader
    leader_id = get_in(squad.settings || %{}, ["leader_agent_id"])
    if leader_id do
      Enum.find(members, &(&1.agent_id == leader_id))
    else
      # Check for agent with squad-leader role template
      Enum.find(members, fn agent ->
        agent = Hub.Repo.preload(agent, [:role_template])
        agent.role_template && agent.role_template.slug == "squad-leader"
      end)
    end
  rescue
    _ -> nil
  end

  defp squad_description(squad) do
    get_in(squad.settings || %{}, ["description"]) || ""
  end

  defp load_registered_agents_detail(fleet_id) do
    import Ecto.Query
    from(a in Hub.Auth.Agent,
      where: a.fleet_id == ^fleet_id,
      order_by: [desc: a.inserted_at],
      preload: [:role_template, :squad]
    ) |> Hub.Repo.all()
  end

  defp load_agent_kanban_tasks(agent_id, fleet_id) do
    case Hub.Kanban.agent_queue(agent_id, fleet_id) do
      tasks when is_list(tasks) -> Enum.take(tasks, 5)
      _ -> []
    end
  rescue
    _ -> []
  end

  defp tier_for_agent(agent) do
    Hub.Messaging.AccessControl.agent_tier(agent)
  rescue
    _ -> 4
  end

  defp tier_badge_class(tier) do
    case tier do
      0 -> "bg-purple-500/15 text-purple-400 border-purple-500/20"
      1 -> "bg-emerald-500/15 text-emerald-400 border-emerald-500/20"
      2 -> "bg-yellow-500/15 text-yellow-400 border-yellow-500/20"
      3 -> "bg-orange-500/15 text-orange-400 border-orange-500/20"
      _ -> "bg-red-500/15 text-red-400 border-red-500/20"
    end
  end

  defp load_conversation(fleet_id, agent_id) do
    case Hub.DirectMessage.history(fleet_id, "dashboard", agent_id, limit: 50) do
      {:ok, msgs} -> msgs
      {:error, _} -> []
    end
  end

  defp maybe_reload_kanban(socket) do
    if socket.assigns.current_view == "kanban" do
      load_kanban_board(socket)
    else
      socket
    end
  end

  defp load_kanban_board(socket) do
    fleet_id = socket.assigns.fleet_id
    board = Hub.Kanban.fleet_board(fleet_id)
    stats = Hub.Kanban.board_stats(fleet_id)
    squads = try do Hub.Fleets.list_squads(fleet_id) rescue _ -> [] end

    # Apply filters
    filters = socket.assigns.kanban_filters
    board = filter_kanban_board(board, filters)

    assign(socket,
      kanban_board: board,
      kanban_stats: stats,
      kanban_squads: squads
    )
  end

  defp filter_kanban_board(board, filters) do
    Enum.map(board, fn {lane, tasks} ->
      filtered = tasks
      |> then(fn tasks ->
        case filters[:squad_id] do
          nil -> tasks
          sid -> Enum.filter(tasks, &(&1.squad_id == sid))
        end
      end)
      |> then(fn tasks ->
        case filters[:assigned_to] do
          nil -> tasks
          agent -> Enum.filter(tasks, &(&1.assigned_to == agent))
        end
      end)
      |> then(fn tasks ->
        case filters[:priority] do
          nil -> tasks
          pri -> Enum.filter(tasks, &(&1.priority == pri))
        end
      end)
      |> then(fn tasks ->
        case filters[:search] do
          nil -> tasks
          "" -> tasks
          q ->
            q = String.downcase(q)
            Enum.filter(tasks, fn t ->
              String.contains?(String.downcase(t.title || ""), q) ||
              String.contains?(String.downcase(t.task_id || ""), q) ||
              String.contains?(String.downcase(t.assigned_to || ""), q)
            end)
        end
      end)
      {lane, filtered}
    end)
    |> Map.new()
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
  # Add Agent Wizard
  # ══════════════════════════════════════════════════════════

  defp render_add_agent_wizard(assigns) do
    ~H"""
    <div class="fixed inset-0 z-[60] flex items-center justify-center animate-fade-in" phx-window-keydown="esc_pressed" phx-key="Escape">
      <%!-- Backdrop --%>
      <div class="absolute inset-0 bg-black/60 backdrop-blur-sm" phx-click="close_wizard"></div>

      <%!-- Modal --%>
      <div class="relative w-full max-w-xl mx-4 bg-zinc-900 border border-zinc-800 rounded-xl shadow-2xl overflow-hidden">
        <%!-- Header --%>
        <div class="flex items-center justify-between px-6 py-4 border-b border-zinc-800">
          <div class="flex items-center gap-3">
            <div class="w-8 h-8 rounded-lg bg-amber-500/15 border border-amber-500/25 flex items-center justify-center">
              <Icons.plus class="w-4 h-4 text-amber-400" />
            </div>
            <div>
              <h3 class="text-sm font-semibold text-zinc-100">Add Agent</h3>
              <p class="text-[11px] text-zinc-500">Step <%= @wizard_step %> of 4</p>
            </div>
          </div>
          <button phx-click="close_wizard" class="text-zinc-500 hover:text-zinc-300 transition-colors p-1">
            <Icons.x class="w-4 h-4" />
          </button>
        </div>

        <%!-- Step indicator --%>
        <div class="px-6 pt-4">
          <div class="flex items-center gap-1.5">
            <%= for step <- 1..4 do %>
              <div class={"h-1 rounded-full flex-1 transition-colors duration-200 " <>
                cond do
                  step < @wizard_step -> "bg-amber-400"
                  step == @wizard_step -> "bg-amber-400"
                  true -> "bg-zinc-800"
                end
              }></div>
            <% end %>
          </div>
        </div>

        <%!-- Content --%>
        <div class="px-6 py-5">
          <%= case @wizard_step do %>
            <% 1 -> %>
              <%!-- Step 1: Pick Framework --%>
              <div class="space-y-4">
                <div>
                  <h4 class="text-sm font-medium text-zinc-200">How are you connecting?</h4>
                  <p class="text-xs text-zinc-500 mt-1">Pick your framework — we'll show you the right code</p>
                </div>

                <div class="grid grid-cols-2 gap-2">
                  <%= for {id, label, subtitle, icon} <- [
                    {"openclaw", "OpenClaw", "Plugin", :plug},
                    {"python", "Python", "SDK", :code},
                    {"nodejs", "Node.js", "SDK", :package},
                    {"terminal", "Terminal", "CLI", :terminal},
                    {"other", "Other", "Manual", :settings}
                  ] do %>
                    <button
                      phx-click="wizard_select_framework"
                      phx-value-framework={id}
                      class="group flex items-center gap-3 p-3 rounded-lg border border-zinc-800 bg-zinc-900 hover:border-amber-500/40 hover:bg-amber-500/5 transition-all duration-150 text-left"
                    >
                      <div class="w-9 h-9 rounded-lg bg-zinc-800 group-hover:bg-amber-500/15 flex items-center justify-center transition-colors">
                        <%= render_wizard_icon(icon, assigns) %>
                      </div>
                      <div>
                        <div class="text-xs font-medium text-zinc-200 group-hover:text-amber-300 transition-colors"><%= label %></div>
                        <div class="text-[10px] text-zinc-600"><%= subtitle %></div>
                      </div>
                    </button>
                  <% end %>
                </div>
              </div>

            <% 2 -> %>
              <%!-- Step 2: Name Your Agent --%>
              <div class="space-y-4">
                <div>
                  <h4 class="text-sm font-medium text-zinc-200">Name your agent</h4>
                  <p class="text-xs text-zinc-500 mt-1">Optional — a name will be auto-generated if blank</p>
                </div>

                <div>
                  <.input
                    type="text"
                    placeholder="my-agent"
                    value={@wizard_agent_name}
                    phx-keyup="wizard_set_name"
                    class="bg-zinc-950 border-zinc-800 text-zinc-100 placeholder:text-zinc-600 focus:border-amber-500/50"
                  />
                </div>

                <div class="flex items-center justify-between pt-2">
                  <button phx-click="wizard_back" class="flex items-center gap-1.5 text-xs text-zinc-500 hover:text-zinc-300 transition-colors">
                    <Icons.arrow_left class="w-3.5 h-3.5" /> Back
                  </button>
                  <.button variant="default" phx-click="wizard_next" class="bg-amber-500 hover:bg-amber-400 text-zinc-950 font-medium text-xs px-4">
                    Next →
                  </.button>
                </div>
              </div>

            <% 3 -> %>
              <%!-- Step 3: Copy & Connect --%>
              <div class="space-y-4">
                <div>
                  <h4 class="text-sm font-medium text-zinc-200">Copy & connect</h4>
                  <p class="text-xs text-zinc-500 mt-1">Paste this into your project, then click "Check now"</p>
                </div>

                <div class="relative">
                  <pre class="bg-zinc-950 rounded-lg p-4 font-mono text-[11px] text-zinc-300 overflow-x-auto border border-zinc-800 leading-relaxed whitespace-pre-wrap"><%= wizard_snippet(@wizard_framework, @wizard_live_key, @fleet_id, @wizard_agent_name) %></pre>
                  <button
                    class="absolute top-2 right-2 p-1.5 rounded-md bg-zinc-800/80 hover:bg-zinc-700 text-zinc-400 hover:text-zinc-200 transition-colors"
                    title="Copy to clipboard"
                    id="wizard-copy-btn"
                    data-clipboard={wizard_snippet(@wizard_framework, @wizard_live_key, @fleet_id, @wizard_agent_name)}
                    onclick="navigator.clipboard.writeText(this.dataset.clipboard).then(() => { this.innerHTML='<svg class=&quot;w-3.5 h-3.5 text-green-400&quot; viewBox=&quot;0 0 24 24&quot; fill=&quot;none&quot; stroke=&quot;currentColor&quot; stroke-width=&quot;2&quot;><path d=&quot;M20 6 9 17l-5-5&quot;/></svg>'; setTimeout(() => { this.innerHTML='<svg class=&quot;w-3.5 h-3.5&quot; viewBox=&quot;0 0 24 24&quot; fill=&quot;none&quot; stroke=&quot;currentColor&quot; stroke-width=&quot;2&quot;><rect width=&quot;8&quot; height=&quot;4&quot; x=&quot;8&quot; y=&quot;2&quot; rx=&quot;1&quot;/><path d=&quot;M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2&quot;/></svg>'; }, 2000); });"
                  >
                    <Icons.clipboard class="w-3.5 h-3.5" />
                  </button>
                </div>

                <div class="flex items-center justify-between pt-2">
                  <button phx-click="wizard_back" class="flex items-center gap-1.5 text-xs text-zinc-500 hover:text-zinc-300 transition-colors">
                    <Icons.arrow_left class="w-3.5 h-3.5" /> Back
                  </button>
                  <.button variant="default" phx-click="wizard_start_waiting" class="bg-amber-500 hover:bg-amber-400 text-zinc-950 font-medium text-xs px-4">
                    I've connected — check now
                  </.button>
                </div>
              </div>

            <% 4 -> %>
              <%!-- Step 4: Waiting / Success --%>
              <div class="space-y-4">
                <%= if @wizard_connected_agent do %>
                  <%!-- Success --%>
                  <div class="text-center py-6 space-y-4">
                    <div class="inline-flex items-center justify-center w-14 h-14 rounded-full bg-green-500/15 border border-green-500/25">
                      <Icons.check class="w-7 h-7 text-green-400" />
                    </div>
                    <div>
                      <h4 class="text-base font-semibold text-zinc-100">Agent connected!</h4>
                      <p class="text-sm text-zinc-400 mt-1">
                        <span class="text-amber-400 font-medium"><%= @wizard_connected_agent.name %></span> is now in your fleet
                      </p>
                    </div>
                    <div class="flex items-center justify-center gap-3 pt-2">
                      <.button
                        variant="outline"
                        phx-click="navigate"
                        phx-value-view="agents"
                        phx-value-agent={@wizard_connected_agent.id}
                        class="border-zinc-700 text-zinc-300 hover:text-zinc-100"
                      >
                        View Agent
                      </.button>
                      <.button variant="default" phx-click="open_wizard" class="bg-amber-500 hover:bg-amber-400 text-zinc-950 font-medium">
                        Add Another
                      </.button>
                    </div>
                  </div>
                <% else %>
                  <%!-- Waiting --%>
                  <div class="text-center py-8 space-y-4">
                    <div class="inline-flex items-center justify-center w-14 h-14 rounded-full bg-amber-500/10 border border-amber-500/20">
                      <Icons.loader class="w-7 h-7 text-amber-400 animate-spin" />
                    </div>
                    <div>
                      <h4 class="text-sm font-medium text-zinc-200">Waiting for your agent to connect…</h4>
                      <p class="text-xs text-zinc-500 mt-1">Run the code above, then we'll detect it automatically</p>
                    </div>
                    <div class="flex items-center justify-center gap-1.5 text-zinc-600">
                      <span class="w-1.5 h-1.5 rounded-full bg-amber-400 animate-pulse"></span>
                      <span class="w-1.5 h-1.5 rounded-full bg-amber-400 animate-pulse [animation-delay:0.2s]"></span>
                      <span class="w-1.5 h-1.5 rounded-full bg-amber-400 animate-pulse [animation-delay:0.4s]"></span>
                    </div>
                  </div>

                  <div class="flex items-center justify-between pt-2">
                    <button phx-click="wizard_back" class="flex items-center gap-1.5 text-xs text-zinc-500 hover:text-zinc-300 transition-colors">
                      <Icons.arrow_left class="w-3.5 h-3.5" /> Back
                    </button>
                    <button phx-click="close_wizard" class="text-xs text-zinc-500 hover:text-zinc-300 transition-colors">
                      Cancel
                    </button>
                  </div>
                <% end %>
              </div>

            <% _ -> %>
              <div></div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp render_wizard_icon(icon, assigns) do
    case icon do
      :plug -> ~H"<Icons.plug class='w-4 h-4 text-zinc-400 group-hover:text-amber-400 transition-colors' />"
      :code -> ~H"<Icons.code class='w-4 h-4 text-zinc-400 group-hover:text-amber-400 transition-colors' />"
      :package -> ~H"<Icons.package class='w-4 h-4 text-zinc-400 group-hover:text-amber-400 transition-colors' />"
      :terminal -> ~H"<Icons.terminal class='w-4 h-4 text-zinc-400 group-hover:text-amber-400 transition-colors' />"
      :settings -> ~H"<Icons.settings class='w-4 h-4 text-zinc-400 group-hover:text-amber-400 transition-colors' />"
      _ -> ~H"<Icons.settings class='w-4 h-4 text-zinc-400 group-hover:text-amber-400 transition-colors' />"
    end
  end

  defp wizard_snippet("openclaw", key, fleet_id, name) do
    name = if name == "" or is_nil(name), do: "my-agent", else: name
    """
    # Add to your openclaw.yaml
    ringforge:
      enabled: true
      server: "wss://ringforge.wejoona.com"
      apiKey: "#{key}"
      fleetId: "#{fleet_id}"
      agentName: "#{name}"
      capabilities: ["code", "research"]\
    """
  end

  defp wizard_snippet("python", key, _fleet_id, name) do
    name = if name == "" or is_nil(name), do: "my-agent", else: name
    """
    pip install ringforge
    # ──────────────
    from ringforge import Agent
    agent = Agent(
        key="#{key}",
        name="#{name}",
        server="wss://ringforge.wejoona.com"
    )
    agent.connect()\
    """
  end

  defp wizard_snippet("nodejs", key, _fleet_id, name) do
    name = if name == "" or is_nil(name), do: "my-agent", else: name
    """
    npm install ringforge
    // ──────────────
    const { Agent } = require('ringforge');
    const agent = new Agent({
      key: '#{key}',
      name: '#{name}',
      server: 'wss://ringforge.wejoona.com'
    });
    agent.connect();\
    """
  end

  defp wizard_snippet("terminal", key, _fleet_id, name) do
    name = if name == "" or is_nil(name), do: "my-agent", else: name
    """
    npx ringforge-connect \\
      --key #{key} \\
      --name "#{name}" \\
      --server wss://ringforge.wejoona.com\
    """
  end

  defp wizard_snippet("other", key, _fleet_id, name) do
    name = if name == "" or is_nil(name), do: "my-agent", else: name
    """
    WebSocket: wss://ringforge.wejoona.com/ws
    Auth: {"api_key": "#{key}", "agent": {"name": "#{name}"}}\
    """
  end

  defp wizard_snippet(_, key, fleet_id, name), do: wizard_snippet("other", key, fleet_id, name)

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
