defmodule Hub.Live.MetricsLive do
  @moduledoc """
  LiveView dashboard for Ringforge observability metrics.

  Displays:
  - Fleet overview: connected agents, message rate, active tasks, memory usage
  - SVG charts: connected agents over time, messages per hour, task completion
  - Per-agent stats table
  - System health (BEAM metrics)
  - Active alerts
  """
  use Phoenix.LiveView
  use SaladUI

  alias Hub.Live.Icons

  @refresh_interval_ms 5_000

  # ══════════════════════════════════════════════════════════
  # Mount
  # ══════════════════════════════════════════════════════════

  @impl true
  def mount(_params, session, socket) do
    tenant_id = session["tenant_id"]

    if is_nil(tenant_id) do
      {:ok, redirect(socket, to: "/dashboard")}
    else
      # Load fleet from DB (same pattern as DashboardLive)
      import Ecto.Query
      fleet = Hub.Repo.one(from f in Hub.Auth.Fleet, where: f.tenant_id == ^tenant_id, order_by: [asc: f.inserted_at], limit: 1)
      fleet_id = if fleet, do: fleet.id, else: nil
      fleet_name = if fleet, do: fleet.name, else: "default"

      socket = assign(socket,
        tenant_id: tenant_id,
        fleet_id: fleet_id,
        fleet_name: fleet_name,
        # Metric data
        connected_agents: 0,
        messages_per_min: 0,
        active_tasks: 0,
        memory_usage_pct: 0,
        # Time series (last 24 data points, ~2 hours at 5s refresh shown as 5min buckets)
        agent_history: List.duplicate(0, 24),
        message_history: List.duplicate(0, 24),
        task_history: List.duplicate(0, 24),
        error_history: List.duplicate(0, 24),
        # Per-agent stats
        agent_stats: [],
        # System health
        beam_memory: %{total: 0, processes: 0, binary: 0, ets: 0},
        beam_processes: 0,
        beam_schedulers: 0,
        beam_run_queue: 0,
        beam_io_in: 0,
        beam_io_out: 0,
        # Alerts
        active_alerts: [],
        alert_history: [],
        # Tracking
        last_messages_total: 0,
        last_refresh: System.monotonic_time(:millisecond)
      )

      if connected?(socket) do
        Process.send_after(self(), :refresh, @refresh_interval_ms)
        Phoenix.PubSub.subscribe(Hub.PubSub, "hub:alerts")
        if fleet_id, do: Phoenix.PubSub.subscribe(Hub.PubSub, "fleet:#{fleet_id}")
      end

      socket = refresh_metrics(socket)
      {:ok, socket}
    end
  end

  # ══════════════════════════════════════════════════════════
  # Events
  # ══════════════════════════════════════════════════════════

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_interval_ms)
    {:noreply, refresh_metrics(socket)}
  end

  def handle_info({:alert_triggered, alert}, socket) do
    alerts = [alert | socket.assigns.active_alerts] |> Enum.take(20)
    {:noreply, assign(socket, active_alerts: alerts)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("navigate", %{"view" => "dashboard"}, socket) do
    {:noreply, redirect(socket, to: "/dashboard")}
  end

  def handle_event("dismiss_alert", %{"id" => id}, socket) do
    alerts = Enum.reject(socket.assigns.active_alerts, &(&1.id == id))
    {:noreply, assign(socket, active_alerts: alerts)}
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  # ══════════════════════════════════════════════════════════
  # Metrics Refresh
  # ══════════════════════════════════════════════════════════

  defp refresh_metrics(socket) do
    fleet_id = socket.assigns.fleet_id

    # Connected agents from presence
    connected = if fleet_id do
      Hub.FleetPresence.list("fleet:#{fleet_id}") |> map_size()
    else
      0
    end

    # Messages total from metrics
    current_messages = Hub.Metrics.get(:counter, "ringforge_messages_total", %{fleet_id: fleet_id || "unknown"})
    messages_per_min = max(0, current_messages - socket.assigns.last_messages_total)

    # Active tasks
    active_tasks = try do Hub.Task.tasks_today() rescue _ -> 0 end

    # Memory usage (quota)
    memory_pct = if socket.assigns.tenant_id do
      case Hub.Quota.check(socket.assigns.tenant_id, :memory_entries) do
        {:ok, %{used: used, limit: limit}} when is_integer(limit) and limit > 0 ->
          round(used / limit * 100)
        _ -> 0
      end
    else
      0
    end

    # Task stats from metrics
    tasks_completed = Hub.Metrics.get(:counter, "ringforge_tasks_total", %{fleet_id: fleet_id || "unknown", status: "completed"})
    tasks_failed = Hub.Metrics.get(:counter, "ringforge_tasks_total", %{fleet_id: fleet_id || "unknown", status: "failed"})

    # Update time series (shift left, append new value)
    agent_history = shift_append(socket.assigns.agent_history, connected)
    message_history = shift_append(socket.assigns.message_history, messages_per_min)
    task_history = shift_append(socket.assigns.task_history, tasks_completed)
    error_history = shift_append(socket.assigns.error_history, tasks_failed)

    # Per-agent stats
    agent_stats = if fleet_id do
      Hub.FleetPresence.list("fleet:#{fleet_id}")
      |> Enum.map(fn {agent_id, %{metas: [meta | _]}} ->
        %{
          agent_id: agent_id,
          name: meta[:name] || agent_id,
          state: meta[:state] || "unknown",
          connected_at: meta[:connected_at],
          task: meta[:task],
          capabilities: meta[:capabilities] || []
        }
      end)
      |> Enum.sort_by(& &1.name)
    else
      []
    end

    # BEAM metrics
    memory = :erlang.memory()
    {{:input, io_in}, {:output, io_out}} = :erlang.statistics(:io)
    run_queue = :erlang.statistics(:run_queue_lengths_all) |> Enum.sum()

    # Alerts
    active_alerts = try do Hub.Alerts.active_alerts() rescue _ -> [] end

    assign(socket,
      connected_agents: connected,
      messages_per_min: messages_per_min,
      active_tasks: active_tasks,
      memory_usage_pct: memory_pct,
      agent_history: agent_history,
      message_history: message_history,
      task_history: task_history,
      error_history: error_history,
      agent_stats: agent_stats,
      beam_memory: %{
        total: Keyword.get(memory, :total, 0),
        processes: Keyword.get(memory, :processes, 0),
        binary: Keyword.get(memory, :binary, 0),
        ets: Keyword.get(memory, :ets, 0)
      },
      beam_processes: :erlang.system_info(:process_count),
      beam_schedulers: :erlang.system_info(:schedulers_online),
      beam_run_queue: run_queue,
      beam_io_in: io_in,
      beam_io_out: io_out,
      active_alerts: active_alerts,
      last_messages_total: current_messages,
      last_refresh: System.monotonic_time(:millisecond)
    )
  end

  defp shift_append(list, value) do
    (tl(list) ++ [value])
  end

  # ══════════════════════════════════════════════════════════
  # Render
  # ══════════════════════════════════════════════════════════

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-zinc-950 text-zinc-100">
      <%!-- Header --%>
      <header class="h-12 border-b border-zinc-800 flex items-center justify-between px-4 bg-zinc-950">
        <div class="flex items-center gap-3">
          <a href="/dashboard" class="flex items-center gap-2 hover:opacity-80 transition-opacity">
            <div class="w-7 h-7 rounded-lg bg-amber-500/15 border border-amber-500/25 flex items-center justify-center text-amber-400">
              <Icons.zap class="w-3.5 h-3.5" />
            </div>
            <span class="text-sm font-semibold text-zinc-200">Ring<span class="text-amber-400">Forge</span></span>
          </a>
          <span class="text-zinc-600">›</span>
          <span class="text-sm text-zinc-400">Metrics & Observability</span>
        </div>
        <div class="flex items-center gap-2">
          <.badge variant="outline" class="border-green-500/20 bg-green-500/5 text-green-400 text-[10px]">
            <span class="w-1.5 h-1.5 rounded-full bg-green-400 animate-pulse mr-1.5"></span>
            Live
          </.badge>
          <a href="/dashboard" class="text-xs text-zinc-500 hover:text-zinc-300">← Dashboard</a>
        </div>
      </header>

      <div class="p-6 space-y-6 max-w-7xl mx-auto">
        <%!-- Alerts Banner --%>
        <%= if @active_alerts != [] do %>
          <div class="space-y-2">
            <%= for alert <- Enum.take(@active_alerts, 3) do %>
              <div class={"flex items-center justify-between rounded-lg px-4 py-2.5 text-sm border " <>
                if(alert.severity == :critical,
                  do: "bg-red-500/10 border-red-500/20 text-red-300",
                  else: "bg-amber-500/10 border-amber-500/20 text-amber-300")}>
                <div class="flex items-center gap-2">
                  <Icons.alert_triangle class="w-4 h-4" />
                  <span><%= alert.message %></span>
                  <span class="text-[10px] opacity-60"><%= alert.triggered_at %></span>
                </div>
                <button phx-click="dismiss_alert" phx-value-id={alert.id} class="text-zinc-500 hover:text-zinc-300">
                  <Icons.x class="w-4 h-4" />
                </button>
              </div>
            <% end %>
          </div>
        <% end %>

        <%!-- Fleet Overview Stats --%>
        <div class="grid grid-cols-2 lg:grid-cols-4 gap-3">
          <.metric_card label="Connected Agents" value={to_string(@connected_agents)} icon={:bot} color="green" />
          <.metric_card label="Messages / Refresh" value={to_string(@messages_per_min)} icon={:message_square} color="blue" />
          <.metric_card label="Active Tasks" value={to_string(@active_tasks)} icon={:layers} color="amber" />
          <.metric_card label="Memory Usage" value={"#{@memory_usage_pct}%"} icon={:brain} color="purple" />
        </div>

        <%!-- Charts Row --%>
        <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
          <.chart_card title="Connected Agents" data={@agent_history} color="#22c55e" max_label="agents" />
          <.chart_card title="Messages" data={@message_history} color="#3b82f6" max_label="msgs" />
          <.chart_card title="Tasks Completed" data={@task_history} color="#f59e0b" max_label="tasks" />
          <.chart_card title="Errors" data={@error_history} color="#ef4444" max_label="errors" />
        </div>

        <%!-- Per-Agent Stats --%>
        <.card class="bg-zinc-900 border-zinc-800">
          <.card_header>
            <.card_title class="text-sm font-medium text-zinc-300">Per-Agent Stats</.card_title>
          </.card_header>
          <.card_content>
            <%= if @agent_stats == [] do %>
              <p class="text-sm text-zinc-500 text-center py-4">No agents connected</p>
            <% else %>
              <div class="overflow-x-auto">
                <table class="w-full text-sm">
                  <thead>
                    <tr class="border-b border-zinc-800 text-zinc-500 text-xs">
                      <th class="text-left py-2 pr-4 font-medium">Agent</th>
                      <th class="text-left py-2 pr-4 font-medium">State</th>
                      <th class="text-left py-2 pr-4 font-medium">Task</th>
                      <th class="text-left py-2 pr-4 font-medium">Connected</th>
                      <th class="text-left py-2 font-medium">Capabilities</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for agent <- @agent_stats do %>
                      <tr class="border-b border-zinc-800/50 hover:bg-zinc-800/30">
                        <td class="py-2 pr-4">
                          <div class="flex items-center gap-2">
                            <span class={"w-2 h-2 rounded-full " <> state_color(agent.state)}></span>
                            <span class="text-zinc-200 font-medium"><%= agent.name %></span>
                          </div>
                        </td>
                        <td class="py-2 pr-4 text-zinc-400"><%= agent.state %></td>
                        <td class="py-2 pr-4 text-zinc-400 max-w-[200px] truncate"><%= agent.task || "—" %></td>
                        <td class="py-2 pr-4 text-zinc-500 text-xs"><%= agent.connected_at || "—" %></td>
                        <td class="py-2">
                          <div class="flex gap-1 flex-wrap">
                            <%= for cap <- Enum.take(agent.capabilities, 3) do %>
                              <.badge variant="outline" class="text-[10px] px-1 py-0 border-zinc-700 text-zinc-500"><%= cap %></.badge>
                            <% end %>
                          </div>
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            <% end %>
          </.card_content>
        </.card>

        <%!-- System Health --%>
        <.card class="bg-zinc-900 border-zinc-800">
          <.card_header>
            <.card_title class="text-sm font-medium text-zinc-300">BEAM System Health</.card_title>
          </.card_header>
          <.card_content>
            <div class="grid grid-cols-2 lg:grid-cols-4 gap-4">
              <div>
                <div class="text-xs text-zinc-500 mb-1">Total Memory</div>
                <div class="text-lg font-bold text-zinc-200"><%= format_bytes(@beam_memory.total) %></div>
                <div class="text-xs text-zinc-600 mt-0.5">
                  Proc: <%= format_bytes(@beam_memory.processes) %> ·
                  Bin: <%= format_bytes(@beam_memory.binary) %> ·
                  ETS: <%= format_bytes(@beam_memory.ets) %>
                </div>
              </div>
              <div>
                <div class="text-xs text-zinc-500 mb-1">Processes</div>
                <div class="text-lg font-bold text-zinc-200"><%= format_number(@beam_processes) %></div>
              </div>
              <div>
                <div class="text-xs text-zinc-500 mb-1">Schedulers</div>
                <div class="text-lg font-bold text-zinc-200"><%= @beam_schedulers %></div>
                <div class="text-xs text-zinc-600 mt-0.5">Run queue: <%= @beam_run_queue %></div>
              </div>
              <div>
                <div class="text-xs text-zinc-500 mb-1">I/O Total</div>
                <div class="text-lg font-bold text-zinc-200"><%= format_bytes(@beam_io_in + @beam_io_out) %></div>
                <div class="text-xs text-zinc-600 mt-0.5">
                  In: <%= format_bytes(@beam_io_in) %> · Out: <%= format_bytes(@beam_io_out) %>
                </div>
              </div>
            </div>
          </.card_content>
        </.card>
      </div>
    </div>
    """
  end

  # ══════════════════════════════════════════════════════════
  # Components
  # ══════════════════════════════════════════════════════════

  defp metric_card(assigns) do
    assigns = assign_new(assigns, :color, fn -> "amber" end)

    ~H"""
    <.card class="bg-zinc-900 border-zinc-800">
      <.card_content class="p-4">
        <div class="flex items-center gap-2 mb-2">
          <div class={"p-1.5 rounded-lg " <> color_bg(@color)}>
            <%= render_icon(@icon, "w-3.5 h-3.5") %>
          </div>
          <span class="text-xs text-zinc-400"><%= @label %></span>
        </div>
        <div class="text-2xl font-bold text-zinc-100"><%= @value %></div>
      </.card_content>
    </.card>
    """
  end

  defp chart_card(assigns) do
    data = assigns.data
    max_val = max(Enum.max(data), 1)
    points = data
    |> Enum.with_index()
    |> Enum.map(fn {val, i} ->
      x = i / max(length(data) - 1, 1) * 300
      y = 80 - (val / max_val * 70)
      {x, y}
    end)

    polyline_points = points |> Enum.map(fn {x, y} -> "#{x},#{y}" end) |> Enum.join(" ")

    # Area path
    area_points = points |> Enum.map(fn {x, y} -> "#{x},#{y}" end) |> Enum.join(" ")
    {first_x, _} = List.first(points, {0, 80})
    {last_x, _} = List.last(points, {300, 80})
    area_path = "M #{first_x},80 L #{area_points} L #{last_x},80 Z"

    assigns = assign(assigns,
      max_val: max_val,
      polyline_points: polyline_points,
      area_path: area_path
    )

    ~H"""
    <.card class="bg-zinc-900 border-zinc-800">
      <.card_header class="pb-1">
        <div class="flex items-center justify-between">
          <.card_title class="text-xs font-medium text-zinc-400"><%= @title %></.card_title>
          <span class="text-[10px] text-zinc-600">max: <%= @max_val %> <%= @max_label %></span>
        </div>
      </.card_header>
      <.card_content class="pb-3">
        <svg viewBox="0 0 300 90" class="w-full h-20" preserveAspectRatio="none">
          <%!-- Grid lines --%>
          <line x1="0" y1="10" x2="300" y2="10" stroke="#27272a" stroke-width="0.5" />
          <line x1="0" y1="45" x2="300" y2="45" stroke="#27272a" stroke-width="0.5" />
          <line x1="0" y1="80" x2="300" y2="80" stroke="#27272a" stroke-width="0.5" />
          <%!-- Area fill --%>
          <path d={@area_path} fill={@color} opacity="0.1" />
          <%!-- Line --%>
          <polyline
            points={@polyline_points}
            fill="none"
            stroke={@color}
            stroke-width="2"
            stroke-linejoin="round"
            stroke-linecap="round"
          />
        </svg>
      </.card_content>
    </.card>
    """
  end

  # ── Helpers ────────────────────────────────────────────────

  defp render_icon(:bot, class), do: Icons.bot(%{class: class})
  defp render_icon(:message_square, class), do: Icons.message_square(%{class: class})
  defp render_icon(:layers, class), do: Icons.layers(%{class: class})
  defp render_icon(:brain, class), do: Icons.brain(%{class: class})
  defp render_icon(_, class), do: Icons.activity(%{class: class})

  defp color_bg("green"), do: "bg-green-500/15 text-green-400"
  defp color_bg("blue"), do: "bg-blue-500/15 text-blue-400"
  defp color_bg("amber"), do: "bg-amber-500/15 text-amber-400"
  defp color_bg("purple"), do: "bg-purple-500/15 text-purple-400"
  defp color_bg(_), do: "bg-zinc-700 text-zinc-400"

  defp state_color("online"), do: "bg-green-400"
  defp state_color("busy"), do: "bg-amber-400"
  defp state_color("away"), do: "bg-zinc-400"
  defp state_color(_), do: "bg-zinc-600"

  defp format_bytes(bytes) when bytes >= 1_073_741_824, do: "#{Float.round(bytes / 1_073_741_824, 1)} GB"
  defp format_bytes(bytes) when bytes >= 1_048_576, do: "#{Float.round(bytes / 1_048_576, 1)} MB"
  defp format_bytes(bytes) when bytes >= 1024, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_bytes(bytes), do: "#{bytes} B"

  defp format_number(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_number(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_number(n), do: to_string(n)
end
