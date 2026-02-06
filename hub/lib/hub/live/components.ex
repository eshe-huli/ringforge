defmodule Hub.Live.Components do
  @moduledoc """
  Shared UI components for the Ringforge dashboard.

  All components use function components compatible with LiveView 0.20.x.
  Uses EEx `<%= %>` syntax — no curly-brace HEEx attribute syntax.
  """
  use Phoenix.Component

  # ── Stat Card ──────────────────────────────────────────────

  @doc """
  Renders a stat card with label, value, optional delta, and icon.

  ## Assigns
    * `:label` - Card label (e.g. "Total Agents")
    * `:value` - Display value
    * `:icon` - SVG icon string or emoji
    * `:delta` - Optional change indicator (string like "+3" or "-1")
    * `:delta_type` - :positive, :negative, or :neutral
    * `:color` - accent color class (e.g. "amber", "green", "blue", "purple")
  """
  def stat_card(assigns) do
    assigns = assign_new(assigns, :delta, fn -> nil end)
    assigns = assign_new(assigns, :delta_type, fn -> :neutral end)
    assigns = assign_new(assigns, :color, fn -> "amber" end)

    ~H"""
    <div class="glass-card rounded-xl p-5 group hover:scale-[1.02] transition-all duration-300 relative overflow-hidden">
      <%!-- Subtle gradient overlay --%>
      <div class={"absolute inset-0 opacity-0 group-hover:opacity-100 transition-opacity duration-500 pointer-events-none " <> stat_gradient(@color)}></div>

      <div class="relative z-10">
        <div class="flex items-start justify-between mb-3">
          <span class="text-[10px] font-semibold text-rf-text-muted uppercase tracking-[0.2em]"><%= @label %></span>
          <div class={"w-8 h-8 rounded-lg flex items-center justify-center text-sm " <> stat_icon_bg(@color)}>
            <%= @icon %>
          </div>
        </div>
        <div class="flex items-end gap-3">
          <span class="text-3xl font-bold text-rf-text tracking-tight"><%= @value %></span>
          <%= if @delta do %>
            <span class={"text-xs font-medium px-2 py-0.5 rounded-full mb-1 " <> delta_style(@delta_type)}>
              <%= @delta %>
            </span>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp stat_gradient("amber"), do: "bg-gradient-to-br from-amber-500/5 to-transparent"
  defp stat_gradient("green"), do: "bg-gradient-to-br from-green-500/5 to-transparent"
  defp stat_gradient("blue"), do: "bg-gradient-to-br from-blue-500/5 to-transparent"
  defp stat_gradient("purple"), do: "bg-gradient-to-br from-purple-500/5 to-transparent"
  defp stat_gradient(_), do: "bg-gradient-to-br from-white/5 to-transparent"

  defp stat_icon_bg("amber"), do: "bg-amber-500/10 text-amber-400 border border-amber-500/20"
  defp stat_icon_bg("green"), do: "bg-green-500/10 text-green-400 border border-green-500/20"
  defp stat_icon_bg("blue"), do: "bg-blue-500/10 text-blue-400 border border-blue-500/20"
  defp stat_icon_bg("purple"), do: "bg-purple-500/10 text-purple-400 border border-purple-500/20"
  defp stat_icon_bg(_), do: "bg-white/10 text-white/60 border border-white/10"

  defp delta_style(:positive), do: "bg-green-500/15 text-green-400"
  defp delta_style(:negative), do: "bg-red-500/15 text-red-400"
  defp delta_style(_), do: "bg-rf-border text-rf-text-sec"

  # ── Agent Card (Grid) ─────────────────────────────────────

  @doc """
  Renders an agent card for grid layout on the overview page.
  """
  def agent_grid_card(assigns) do
    ~H"""
    <div
      phx-click="navigate"
      phx-value-view="agents"
      phx-value-agent={@agent_id}
      class="glass-card rounded-xl p-4 cursor-pointer group hover:scale-[1.01] transition-all duration-200 relative overflow-hidden"
    >
      <div class="flex items-center gap-3 mb-3">
        <%!-- Avatar placeholder --%>
        <div class={"w-10 h-10 rounded-lg flex items-center justify-center text-base font-bold " <> avatar_bg(@meta[:state])}>
          <%= avatar_initial(@meta[:name] || @agent_id) %>
        </div>
        <div class="min-w-0 flex-1">
          <div class="flex items-center gap-2">
            <span class="font-semibold text-sm text-rf-text truncate"><%= @meta[:name] || @agent_id %></span>
            <span
              class={"inline-block w-2 h-2 rounded-full shrink-0 " <> state_color(@meta[:state]) <> if(@meta[:state] in ["online", "busy"], do: " pulse-dot", else: "")}
              style={"color: " <> state_dot_color(@meta[:state]) <> ";"}
            ></span>
          </div>
          <span class={"text-[10px] px-2 py-0.5 rounded-full font-medium " <> state_badge(@meta[:state])}>
            <%= @meta[:state] || "unknown" %>
          </span>
        </div>
      </div>
      <%= if @meta[:task] do %>
        <div class="text-xs text-rf-text-sec truncate flex items-center gap-1.5 mb-2" title={@meta[:task]}>
          <span class="text-amber-400/60">▸</span>
          <span><%= @meta[:task] %></span>
        </div>
      <% else %>
        <div class="text-xs text-rf-text-muted/50 italic mb-2">No active task</div>
      <% end %>
      <%= if @meta[:capabilities] && @meta[:capabilities] != [] do %>
        <div class="flex flex-wrap gap-1">
          <%= for cap <- Enum.take(List.wrap(@meta[:capabilities]), 3) do %>
            <span class="text-[9px] px-1.5 py-0.5 rounded bg-rf-border/70 text-rf-text-muted border border-rf-border-bright/30"><%= cap %></span>
          <% end %>
          <%= if length(List.wrap(@meta[:capabilities])) > 3 do %>
            <span class="text-[9px] px-1.5 py-0.5 rounded bg-rf-border/70 text-rf-text-muted">+<%= length(List.wrap(@meta[:capabilities])) - 3 %></span>
          <% end %>
        </div>
      <% end %>
      <%!-- Hover glow --%>
      <div class="absolute inset-0 opacity-0 group-hover:opacity-100 transition-opacity duration-300 pointer-events-none rounded-xl" style="box-shadow: inset 0 0 30px rgba(245,158,11,0.03);"></div>
    </div>
    """
  end

  defp avatar_initial(nil), do: "?"
  defp avatar_initial(""), do: "?"
  defp avatar_initial(name) do
    name
    |> String.trim()
    |> String.first()
    |> String.upcase()
  end

  defp avatar_bg("online"), do: "bg-gradient-to-br from-green-500/20 to-green-600/5 border border-green-500/20 text-green-400"
  defp avatar_bg("busy"), do: "bg-gradient-to-br from-yellow-500/20 to-yellow-600/5 border border-yellow-500/20 text-yellow-400"
  defp avatar_bg("away"), do: "bg-gradient-to-br from-gray-500/20 to-gray-600/5 border border-gray-500/20 text-gray-400"
  defp avatar_bg("offline"), do: "bg-gradient-to-br from-red-500/20 to-red-600/5 border border-red-500/20 text-red-400"
  defp avatar_bg(_), do: "bg-gradient-to-br from-gray-500/20 to-gray-600/5 border border-gray-500/20 text-gray-500"

  # ── Activity Item ──────────────────────────────────────────

  @doc """
  Renders a single activity item with accent bar and details.
  """
  def activity_item(assigns) do
    assigns = assign_new(assigns, :compact, fn -> false end)

    ~H"""
    <div class={"fade-in accent-bar pl-4 py-2.5 pr-3 rounded-lg hover:bg-rf-card/50 group transition-smooth " <> kind_color(@activity.kind)}>
      <div class="flex items-start gap-3">
        <span class="text-[10px] text-rf-text-muted whitespace-nowrap mt-0.5 font-mono">
          <%= format_time(@activity.timestamp) %>
        </span>
        <span class="text-sm mt-px"><%= kind_icon(@activity.kind) %></span>
        <div class="min-w-0 flex-1">
          <div class="flex items-center gap-2">
            <span class="text-sm font-semibold text-rf-text"><%= @activity.agent_name %></span>
            <span class={"text-[10px] px-2 py-0.5 rounded-full font-medium " <> kind_badge_style(@activity.kind)}>
              <%= @activity.kind %>
            </span>
          </div>
          <%= unless @compact do %>
            <div class="text-xs text-rf-text-sec mt-0.5 truncate"><%= @activity.description %></div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # ── Quota Bar ──────────────────────────────────────────────

  @doc """
  Renders a quota usage bar with label and numbers.
  """
  def quota_bar(assigns) do
    pct = quota_percentage(assigns.info)
    assigns = assign(assigns, :pct, pct)

    ~H"""
    <div>
      <div class="flex items-center justify-between text-xs mb-1.5">
        <span class="text-rf-text-sec flex items-center gap-1.5">
          <span><%= @icon %></span>
          <span class="text-[10px] uppercase tracking-wider"><%= @label %></span>
        </span>
        <span class="text-rf-text-muted font-mono text-[11px]">
          <span class="text-rf-text-sec"><%= format_quota_number(@info[:used] || Map.get(@info, :used, 0)) %></span>
          <span class="text-rf-text-muted">/</span>
          <span><%= format_quota_limit(@info[:limit] || Map.get(@info, :limit, 0)) %></span>
        </span>
      </div>
      <div class="h-2 bg-rf-border/50 rounded-full overflow-hidden">
        <div
          class={"h-full rounded-full transition-all duration-700 ease-out " <> quota_bar_style(@pct)}
          style={"width: #{max(@pct, 2)}%"}
        ></div>
      </div>
    </div>
    """
  end

  # ── Large Quota Card ───────────────────────────────────────

  def quota_card(assigns) do
    pct = quota_percentage(assigns.info)
    assigns = assign(assigns, :pct, pct)

    ~H"""
    <div class="glass-card rounded-xl p-5">
      <div class="flex items-center justify-between mb-4">
        <div class="flex items-center gap-3">
          <div class={"w-10 h-10 rounded-lg flex items-center justify-center text-lg " <> stat_icon_bg(@color)}>
            <%= @icon %>
          </div>
          <div>
            <h3 class="text-sm font-semibold text-rf-text"><%= @label %></h3>
            <p class="text-[10px] text-rf-text-muted uppercase tracking-wider">
              <%= format_quota_number(@info[:used] || 0) %> of <%= format_quota_limit(@info[:limit] || 0) %> used
            </p>
          </div>
        </div>
        <div class={"text-2xl font-bold " <> pct_color(@pct)}>
          <%= @pct %>%
        </div>
      </div>
      <div class="h-3 bg-rf-border/50 rounded-full overflow-hidden">
        <div
          class={"h-full rounded-full transition-all duration-700 ease-out " <> quota_bar_style(@pct)}
          style={"width: #{max(@pct, 2)}%"}
        ></div>
      </div>
      <%= if @pct >= 80 do %>
        <div class={"mt-3 text-xs px-3 py-2 rounded-lg " <> if(@pct >= 95, do: "bg-red-500/10 text-red-400 border border-red-500/20", else: "bg-yellow-500/10 text-yellow-400 border border-yellow-500/20")}>
          <%= if @pct >= 95 do %>
            ⚠ Critical: approaching limit. Consider upgrading your plan.
          <% else %>
            ℹ High usage detected. Monitor closely.
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  defp pct_color(pct) when pct >= 95, do: "text-red-400"
  defp pct_color(pct) when pct >= 80, do: "text-yellow-400"
  defp pct_color(_), do: "text-green-400"

  # ── Empty State ────────────────────────────────────────────

  def empty_state(assigns) do
    assigns = assign_new(assigns, :icon, fn -> "◇" end)
    assigns = assign_new(assigns, :subtitle, fn -> nil end)

    ~H"""
    <div class="flex flex-col items-center justify-center py-16 text-center">
      <div class="text-4xl mb-4 float-subtle opacity-30"><%= @icon %></div>
      <p class="text-rf-text-muted text-xs uppercase tracking-wider"><%= @message %></p>
      <%= if @subtitle do %>
        <p class="text-rf-text-muted/50 text-[10px] mt-1"><%= @subtitle %></p>
      <% end %>
      <div class="mt-4 w-24 h-px shimmer rounded"></div>
    </div>
    """
  end

  # ── Loading Skeleton ───────────────────────────────────────

  def skeleton(assigns) do
    assigns = assign_new(assigns, :lines, fn -> 3 end)
    assigns = assign_new(assigns, :type, fn -> "card" end)

    ~H"""
    <div class="animate-pulse">
      <%= if @type == "card" do %>
        <div class="glass-card rounded-xl p-5 space-y-3">
          <div class="h-3 bg-rf-border/60 rounded w-1/3"></div>
          <div class="h-8 bg-rf-border/40 rounded w-1/2"></div>
          <div class="h-2 bg-rf-border/30 rounded w-2/3"></div>
        </div>
      <% else %>
        <div class="space-y-2">
          <%= for _i <- 1..@lines do %>
            <div class="h-10 bg-rf-border/30 rounded-lg"></div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # ── Toast Notification ─────────────────────────────────────

  def toast(assigns) do
    ~H"""
    <div
      class={"fixed top-4 right-4 z-50 toast-enter " <> toast_style(@type)}
      phx-click="clear_toast"
    >
      <div class="flex items-center gap-2 px-4 py-3 rounded-xl text-sm font-medium cursor-pointer shadow-2xl">
        <span><%= toast_icon(@type) %></span>
        <span><%= @message %></span>
      </div>
    </div>
    """
  end

  defp toast_style(:success), do: "bg-green-500/15 text-green-400 border border-green-500/30 backdrop-blur-xl"
  defp toast_style(:error), do: "bg-red-500/15 text-red-400 border border-red-500/30 backdrop-blur-xl"
  defp toast_style(:warning), do: "bg-yellow-500/15 text-yellow-400 border border-yellow-500/30 backdrop-blur-xl"
  defp toast_style(_), do: "bg-rf-card text-rf-text border border-rf-border backdrop-blur-xl"

  defp toast_icon(:success), do: "✓"
  defp toast_icon(:error), do: "✕"
  defp toast_icon(:warning), do: "⚠"
  defp toast_icon(_), do: "ℹ"

  # ── Sidebar Nav Item ───────────────────────────────────────

  def nav_item(assigns) do
    assigns = assign_new(assigns, :badge, fn -> nil end)

    ~H"""
    <button
      phx-click="navigate"
      phx-value-view={@view}
      class={"w-full flex items-center gap-3 px-3 py-2.5 rounded-lg text-sm transition-all duration-200 group " <> if(@active, do: "bg-amber-500/10 text-amber-400 border border-amber-500/15", else: "text-rf-text-sec hover:text-rf-text hover:bg-rf-card/50")}
    >
      <span class={"text-base w-5 text-center " <> if(@active, do: "text-amber-400", else: "text-rf-text-muted group-hover:text-rf-text-sec")}><%= @icon %></span>
      <span class={"font-medium " <> if(@active, do: "", else: "")}><%= @label %></span>
      <%= if @badge do %>
        <span class="ml-auto text-[10px] px-2 py-0.5 rounded-full bg-amber-500/15 text-amber-400 font-mono"><%= @badge %></span>
      <% end %>
    </button>
    """
  end

  # ── Message Bubble ─────────────────────────────────────────

  def message_bubble(assigns) do
    is_self = assigns.msg["from"]["agent_id"] == "dashboard" ||
              (assigns[:from_self] == true)
    assigns = assign(assigns, :is_self, is_self)

    ~H"""
    <div class={"flex " <> if(@is_self, do: "justify-end", else: "justify-start") <> " mb-3"}>
      <div class={"max-w-[75%] rounded-xl px-4 py-2.5 " <> if(@is_self, do: "bg-amber-500/15 border border-amber-500/20 rounded-br-sm", else: "bg-rf-card border border-rf-border rounded-bl-sm")}>
        <div class="flex items-center gap-2 mb-1">
          <span class={"text-[10px] font-semibold " <> if(@is_self, do: "text-amber-400", else: "text-rf-text-sec")}>
            <%= get_in(@msg, ["from", "name"]) || get_in(@msg, ["from", "agent_id"]) || "unknown" %>
          </span>
          <span class="text-[9px] text-rf-text-muted font-mono">
            <%= format_time(@msg["timestamp"]) %>
          </span>
        </div>
        <p class="text-sm text-rf-text leading-relaxed">
          <%= get_in(@msg, ["message", "text"]) || inspect(@msg["message"]) %>
        </p>
      </div>
    </div>
    """
  end

  # ── Agent Table Row ────────────────────────────────────────

  def agent_table_row(assigns) do
    ~H"""
    <tr
      phx-click="select_agent_detail"
      phx-value-agent-id={@agent_id}
      class={"border-b border-rf-border/50 cursor-pointer transition-all duration-150 " <> if(@selected, do: "bg-amber-500/5", else: "hover:bg-rf-card/50")}
    >
      <td class="py-3 px-4">
        <div class="flex items-center gap-2.5">
          <div class={"w-8 h-8 rounded-lg flex items-center justify-center text-xs font-bold " <> avatar_bg(@meta[:state])}>
            <%= avatar_initial(@meta[:name] || @agent_id) %>
          </div>
          <div>
            <span class="text-sm font-semibold text-rf-text"><%= @meta[:name] || @agent_id %></span>
            <div class="text-[10px] text-rf-text-muted font-mono truncate max-w-[150px]"><%= @agent_id %></div>
          </div>
        </div>
      </td>
      <td class="py-3 px-4">
        <div class="flex items-center gap-1.5">
          <span
            class={"inline-block w-2 h-2 rounded-full " <> state_color(@meta[:state]) <> if(@meta[:state] in ["online", "busy"], do: " pulse-dot", else: "")}
            style={"color: " <> state_dot_color(@meta[:state]) <> ";"}
          ></span>
          <span class={"text-xs font-medium " <> state_text_color(@meta[:state])}><%= @meta[:state] || "unknown" %></span>
        </div>
      </td>
      <td class="py-3 px-4">
        <div class="flex flex-wrap gap-1">
          <%= for cap <- Enum.take(List.wrap(@meta[:capabilities] || []), 3) do %>
            <span class="text-[9px] px-1.5 py-0.5 rounded bg-rf-border/70 text-rf-text-muted border border-rf-border-bright/30"><%= cap %></span>
          <% end %>
          <%= if length(List.wrap(@meta[:capabilities] || [])) > 3 do %>
            <span class="text-[9px] text-rf-text-muted">+<%= length(List.wrap(@meta[:capabilities])) - 3 %></span>
          <% end %>
        </div>
      </td>
      <td class="py-3 px-4">
        <span class="text-xs text-rf-text-sec truncate block max-w-[200px]"><%= @meta[:task] || "—" %></span>
      </td>
      <td class="py-3 px-4">
        <span class="text-xs text-rf-text-muted font-mono"><%= format_connected_at(@meta[:connected_at]) %></span>
      </td>
      <td class="py-3 px-4">
        <span class="text-xs text-rf-text-sec"><%= @meta[:framework] || "—" %></span>
      </td>
    </tr>
    """
  end

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

  # ── Shared Helpers (public for use in DashboardLive) ───────

  def state_color("online"), do: "bg-green-400"
  def state_color("busy"), do: "bg-yellow-400"
  def state_color("away"), do: "bg-gray-400"
  def state_color("offline"), do: "bg-red-500"
  def state_color(_), do: "bg-gray-600"

  def state_dot_color("online"), do: "#22c55e"
  def state_dot_color("busy"), do: "#eab308"
  def state_dot_color("away"), do: "#94a3b8"
  def state_dot_color("offline"), do: "#ef4444"
  def state_dot_color(_), do: "#475569"

  def state_badge("online"), do: "bg-green-500/15 text-green-400 border border-green-500/20"
  def state_badge("busy"), do: "bg-yellow-500/15 text-yellow-400 border border-yellow-500/20"
  def state_badge("away"), do: "bg-gray-500/15 text-gray-400 border border-gray-500/20"
  def state_badge("offline"), do: "bg-red-500/15 text-red-400 border border-red-500/20"
  def state_badge(_), do: "bg-gray-500/15 text-gray-400 border border-gray-500/20"

  def kind_icon("task_started"), do: "🚀"
  def kind_icon("task_progress"), do: "⏳"
  def kind_icon("task_completed"), do: "✅"
  def kind_icon("task_failed"), do: "❌"
  def kind_icon("discovery"), do: "💡"
  def kind_icon("question"), do: "❓"
  def kind_icon("alert"), do: "🚨"
  def kind_icon("join"), do: "🟢"
  def kind_icon("leave"), do: "🔴"
  def kind_icon(_), do: "📌"

  def kind_color("task_completed"), do: "text-green-400"
  def kind_color("task_started"), do: "text-blue-400"
  def kind_color("task_progress"), do: "text-cyan-400"
  def kind_color("task_failed"), do: "text-red-400"
  def kind_color("discovery"), do: "text-purple-400"
  def kind_color("question"), do: "text-yellow-400"
  def kind_color("alert"), do: "text-red-400"
  def kind_color("join"), do: "text-green-400"
  def kind_color("leave"), do: "text-gray-500"
  def kind_color(_), do: "text-gray-400"

  def kind_badge_style("task_completed"), do: "bg-green-500/15 text-green-400"
  def kind_badge_style("task_started"), do: "bg-blue-500/15 text-blue-400"
  def kind_badge_style("task_progress"), do: "bg-cyan-500/15 text-cyan-400"
  def kind_badge_style("task_failed"), do: "bg-red-500/15 text-red-400"
  def kind_badge_style("discovery"), do: "bg-purple-500/15 text-purple-400"
  def kind_badge_style("question"), do: "bg-yellow-500/15 text-yellow-400"
  def kind_badge_style("alert"), do: "bg-red-500/15 text-red-400"
  def kind_badge_style("join"), do: "bg-green-500/15 text-green-400"
  def kind_badge_style("leave"), do: "bg-gray-500/15 text-gray-400"
  def kind_badge_style(_), do: "bg-rf-border text-rf-text-sec"

  def format_time(nil), do: "--:--"
  def format_time(""), do: "--:--"
  def format_time(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%H:%M")
      _ -> "--:--"
    end
  end
  def format_time(_), do: "--:--"

  def format_time_full(nil), do: "—"
  def format_time_full(""), do: "—"
  def format_time_full(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
      _ -> "—"
    end
  end
  def format_time_full(_), do: "—"

  def state_sort_order("online"), do: 0
  def state_sort_order("busy"), do: 1
  def state_sort_order("away"), do: 2
  def state_sort_order("offline"), do: 3
  def state_sort_order(_), do: 4

  def quota_percentage(%{used: _, limit: :unlimited}), do: 0
  def quota_percentage(%{used: _used, limit: 0}), do: 0
  def quota_percentage(%{used: used, limit: limit}) when is_integer(limit) and limit > 0 do
    min(round(used / limit * 100), 100)
  end
  def quota_percentage(_), do: 0

  def format_quota_number(n) when is_integer(n) and n >= 1_000_000 do
    "#{Float.round(n / 1_000_000, 1)}M"
  end
  def format_quota_number(n) when is_integer(n) and n >= 1000 do
    "#{Float.round(n / 1000, 1)}K"
  end
  def format_quota_number(n), do: "#{n}"

  def format_quota_limit(:unlimited), do: "∞"
  def format_quota_limit(n) when is_integer(n) and n >= 1_000_000 do
    "#{Float.round(n / 1_000_000, 1)}M"
  end
  def format_quota_limit(n) when is_integer(n) and n >= 1000 do
    "#{Float.round(n / 1000, 1)}K"
  end
  def format_quota_limit(n), do: "#{n}"

  def quota_bar_style(pct) when pct >= 95, do: "bg-gradient-to-r from-red-500 to-red-400 bar-glow-red"
  def quota_bar_style(pct) when pct >= 80, do: "bg-gradient-to-r from-yellow-500 to-yellow-400 bar-glow-yellow"
  def quota_bar_style(_), do: "bg-gradient-to-r from-green-500 to-emerald-400 bar-glow-green"

  def quota_resources do
    [
      {:connected_agents, "Agents", "👤", "amber"},
      {:messages_today, "Messages", "💬", "blue"},
      {:memory_entries, "Memory", "🧠", "purple"},
      {:fleets, "Fleets", "🚢", "green"}
    ]
  end
end
