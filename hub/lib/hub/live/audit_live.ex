defmodule Hub.Live.AuditLive do
  @moduledoc """
  Audit log dashboard page.

  Searchable audit log table with filters by action, actor, target, and date range.
  Plan-gated: Scale + Enterprise only.
  """
  use Phoenix.LiveView
  use SaladUI

  alias Hub.Audit

  @page_size 50

  # ══════════════════════════════════════════════════════════
  # Mount
  # ══════════════════════════════════════════════════════════

  @impl true
  def mount(_params, session, socket) do
    tenant_id = session["tenant_id"]

    unless tenant_id do
      {:ok, redirect(socket, to: "/dashboard")}
    else
      tenant = Hub.Repo.get!(Hub.Auth.Tenant, tenant_id)
      plan = tenant.plan || "free"

      if plan in ["scale", "enterprise"] do
        logs = Audit.list(tenant_id, limit: @page_size)
        total = Audit.count(tenant_id)

        {:ok, assign(socket,
          tenant_id: tenant_id,
          tenant: tenant,
          plan: plan,
          logs: logs,
          total: total,
          page: 0,
          filter_action: "",
          filter_actor: "",
          filter_target: "",
          allowed: true,
          toast: nil
        )}
      else
        {:ok, assign(socket,
          tenant_id: tenant_id,
          tenant: tenant,
          plan: plan,
          logs: [],
          total: 0,
          page: 0,
          filter_action: "",
          filter_actor: "",
          filter_target: "",
          allowed: false,
          toast: nil
        )}
      end
    end
  end

  # ══════════════════════════════════════════════════════════
  # Events
  # ══════════════════════════════════════════════════════════

  @impl true
  def handle_event("back_to_dashboard", _, socket) do
    {:noreply, redirect(socket, to: "/dashboard")}
  end

  def handle_event("filter_action", %{"value" => v}, socket) do
    {:noreply, socket |> assign(filter_action: v, page: 0) |> reload_logs()}
  end

  def handle_event("filter_actor", %{"value" => v}, socket) do
    {:noreply, socket |> assign(filter_actor: v, page: 0) |> reload_logs()}
  end

  def handle_event("filter_target", %{"value" => v}, socket) do
    {:noreply, socket |> assign(filter_target: v, page: 0) |> reload_logs()}
  end

  def handle_event("next_page", _, socket) do
    {:noreply, socket |> assign(page: socket.assigns.page + 1) |> reload_logs()}
  end

  def handle_event("prev_page", _, socket) do
    page = max(0, socket.assigns.page - 1)
    {:noreply, socket |> assign(page: page) |> reload_logs()}
  end

  def handle_event("refresh", _, socket) do
    {:noreply, reload_logs(socket)}
  end

  def handle_event("dismiss_toast", _, socket) do
    {:noreply, assign(socket, toast: nil)}
  end

  # ══════════════════════════════════════════════════════════
  # Render
  # ══════════════════════════════════════════════════════════

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-rf-bg text-rf-text font-mono p-6">
      <!-- Header -->
      <div class="flex items-center justify-between mb-6">
        <div class="flex items-center gap-4">
          <button phx-click="back_to_dashboard" class="text-zinc-400 hover:text-zinc-200 transition-colors">
            ← Dashboard
          </button>
          <h1 class="text-xl font-bold text-zinc-100">Audit Log</h1>
          <span class="text-xs text-zinc-500"><%= @total %> events</span>
        </div>
        <button phx-click="refresh" class="px-3 py-1.5 bg-zinc-800 border border-zinc-700 rounded text-xs text-zinc-300 hover:bg-zinc-700">
          Refresh
        </button>
      </div>

      <%= unless @allowed do %>
        <div class="text-center py-16">
          <div class="text-4xl mb-4">🔒</div>
          <h2 class="text-lg font-bold text-zinc-300 mb-2">Audit Logs — Scale Plan Required</h2>
          <p class="text-zinc-500 text-sm mb-4">
            Audit logs are available on Scale and Enterprise plans.
            Your current plan: <span class="text-amber-400"><%= @plan %></span>
          </p>
          <a href="/billing" class="px-4 py-2 bg-amber-600 rounded text-sm text-zinc-900 font-medium hover:bg-amber-500">
            Upgrade Plan
          </a>
        </div>
      <% else %>
        <!-- Filters -->
        <div class="flex gap-3 mb-4">
          <input
            type="text"
            phx-keyup="filter_action"
            value={@filter_action}
            placeholder="Filter by action..."
            class="bg-zinc-800 border border-zinc-700 rounded px-3 py-1.5 text-xs text-zinc-200 w-48 focus:border-amber-600 focus:outline-none"
          />
          <input
            type="text"
            phx-keyup="filter_actor"
            value={@filter_actor}
            placeholder="Filter by actor..."
            class="bg-zinc-800 border border-zinc-700 rounded px-3 py-1.5 text-xs text-zinc-200 w-48 focus:border-amber-600 focus:outline-none"
          />
          <input
            type="text"
            phx-keyup="filter_target"
            value={@filter_target}
            placeholder="Filter by target..."
            class="bg-zinc-800 border border-zinc-700 rounded px-3 py-1.5 text-xs text-zinc-200 w-48 focus:border-amber-600 focus:outline-none"
          />
        </div>

        <!-- Toast -->
        <%= if @toast do %>
          <div phx-click="dismiss_toast" class="mb-4 p-3 bg-zinc-800 border border-zinc-700 rounded text-xs text-zinc-300 cursor-pointer">
            <%= @toast %>
          </div>
        <% end %>

        <!-- Audit Table -->
        <div class="bg-zinc-900 border border-zinc-800 rounded-lg overflow-hidden">
          <table class="w-full text-xs">
            <thead>
              <tr class="border-b border-zinc-800 text-zinc-500">
                <th class="text-left p-3 font-medium">Time</th>
                <th class="text-left p-3 font-medium">Action</th>
                <th class="text-left p-3 font-medium">Actor</th>
                <th class="text-left p-3 font-medium">Target</th>
                <th class="text-left p-3 font-medium">IP</th>
                <th class="text-left p-3 font-medium">Details</th>
              </tr>
            </thead>
            <tbody>
              <%= for log <- @logs do %>
                <tr class="border-b border-zinc-800/50 hover:bg-zinc-800/30">
                  <td class="p-3 text-zinc-400 whitespace-nowrap">
                    <%= if log.inserted_at, do: Calendar.strftime(log.inserted_at, "%m-%d %H:%M:%S") %>
                  </td>
                  <td class="p-3">
                    <span class={"px-1.5 py-0.5 rounded text-[10px] font-medium " <> action_style(log.action)}>
                      <%= log.action %>
                    </span>
                  </td>
                  <td class="p-3 text-zinc-300">
                    <span class="text-zinc-500"><%= log.actor_type %>:</span>
                    <span class="font-mono"><%= truncate(log.actor_id, 20) %></span>
                  </td>
                  <td class="p-3 text-zinc-300">
                    <%= if log.target_type do %>
                      <span class="text-zinc-500"><%= log.target_type %>:</span>
                      <span class="font-mono"><%= truncate(log.target_id || "", 20) %></span>
                    <% else %>
                      <span class="text-zinc-600">—</span>
                    <% end %>
                  </td>
                  <td class="p-3 text-zinc-500 font-mono"><%= log.ip_address || "—" %></td>
                  <td class="p-3 text-zinc-500">
                    <%= if log.metadata && log.metadata != %{} do %>
                      <span class="text-zinc-400" title={Jason.encode!(log.metadata)}>
                        <%= log.metadata |> Map.keys() |> Enum.take(3) |> Enum.join(", ") %>
                      </span>
                    <% end %>
                  </td>
                </tr>
              <% end %>

              <%= if @logs == [] do %>
                <tr>
                  <td colspan="6" class="p-8 text-center text-zinc-500">
                    No audit events found
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>

        <!-- Pagination -->
        <div class="flex items-center justify-between mt-4 text-xs text-zinc-500">
          <span>
            Showing <%= @page * @page_size + 1 %>–<%= min((@page + 1) * @page_size, @total) %> of <%= @total %>
          </span>
          <div class="flex gap-2">
            <button
              phx-click="prev_page"
              disabled={@page == 0}
              class={"px-3 py-1 rounded border " <> if(@page == 0, do: "border-zinc-800 text-zinc-700", else: "border-zinc-700 text-zinc-300 hover:bg-zinc-800")}
            >
              ← Prev
            </button>
            <button
              phx-click="next_page"
              disabled={(@page + 1) * @page_size >= @total}
              class={"px-3 py-1 rounded border " <> if((@page + 1) * @page_size >= @total, do: "border-zinc-800 text-zinc-700", else: "border-zinc-700 text-zinc-300 hover:bg-zinc-800")}
            >
              Next →
            </button>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # ── Helpers ────────────────────────────────────────────────

  defp reload_logs(socket) do
    opts = [
      limit: @page_size,
      offset: socket.assigns.page * @page_size
    ]

    opts =
      opts
      |> maybe_add_filter(:action, socket.assigns.filter_action)
      |> maybe_add_filter(:actor_type, socket.assigns.filter_actor)
      |> maybe_add_filter(:target_type, socket.assigns.filter_target)

    logs = Audit.list(socket.assigns.tenant_id, opts)
    total = Audit.count(socket.assigns.tenant_id)
    assign(socket, logs: logs, total: total)
  end

  defp maybe_add_filter(opts, _key, ""), do: opts
  defp maybe_add_filter(opts, key, value), do: Keyword.put(opts, key, value)

  defp action_style(action) do
    cond do
      String.contains?(action, "login") -> "bg-blue-900/50 text-blue-400"
      String.contains?(action, "created") -> "bg-green-900/50 text-green-400"
      String.contains?(action, "deleted") or String.contains?(action, "revoked") -> "bg-red-900/50 text-red-400"
      String.contains?(action, "kicked") -> "bg-red-900/50 text-red-400"
      String.contains?(action, "updated") or String.contains?(action, "changed") -> "bg-amber-900/50 text-amber-400"
      true -> "bg-zinc-800 text-zinc-400"
    end
  end

  defp truncate(str, max) do
    if String.length(str) > max do
      String.slice(str, 0, max) <> "…"
    else
      str
    end
  end
end
