defmodule Hub.Live.Components do
  @moduledoc """
  Shared UI components for the Ringforge dashboard.

  Uses SaladUI (shadcn for LiveView) components: Card, Table, Badge,
  Button, Progress, Separator, Sheet, Skeleton, Input.
  Zinc dark theme with amber accents.
  """
  use Phoenix.Component
  use SaladUI

  alias Hub.Live.Icons
  alias Phoenix.LiveView.JS

  # ═══════════════════════════════════════════════════════════
  # Stat Card (SaladUI Card)
  # ═══════════════════════════════════════════════════════════

  @doc """
  Stat card using SaladUI Card component.
  """
  def stat_card(assigns) do
    assigns = assign_new(assigns, :delta, fn -> nil end)
    assigns = assign_new(assigns, :delta_type, fn -> :neutral end)
    assigns = assign_new(assigns, :color, fn -> "amber" end)

    ~H"""
    <.card class="bg-zinc-900 border-zinc-800 hover:border-zinc-700 transition-colors duration-200">
      <.card_header class="pb-2">
        <.card_description class="flex items-center gap-2">
          <div class={"p-1.5 rounded-lg " <> icon_bg(@color)}>
            <%= render_icon(@icon, "w-3.5 h-3.5") %>
          </div>
          <span class="text-xs text-zinc-400"><%= @label %></span>
        </.card_description>
      </.card_header>
      <.card_content>
        <div class="flex items-end gap-2">
          <span class="text-2xl font-bold text-zinc-100"><%= @value %></span>
          <%= if @delta do %>
            <.badge variant="secondary" class={"text-[10px] px-1.5 py-0.5 " <> delta_style(@delta_type)}>
              <%= @delta %>
            </.badge>
          <% end %>
        </div>
      </.card_content>
    </.card>
    """
  end

  defp icon_bg("amber"), do: "bg-amber-500/15 text-amber-400"
  defp icon_bg("green"), do: "bg-green-500/15 text-green-400"
  defp icon_bg("blue"), do: "bg-blue-500/15 text-blue-400"
  defp icon_bg("purple"), do: "bg-purple-500/15 text-purple-400"
  defp icon_bg("red"), do: "bg-red-500/15 text-red-400"
  defp icon_bg(_), do: "bg-zinc-700 text-zinc-400"

  defp delta_style(:positive), do: "bg-green-500/15 text-green-400 border-green-500/20"
  defp delta_style(:negative), do: "bg-red-500/15 text-red-400 border-red-500/20"
  defp delta_style(_), do: "bg-zinc-700 text-zinc-400 border-zinc-600"

  # ═══════════════════════════════════════════════════════════
  # Agent Grid Card (SaladUI Card)
  # ═══════════════════════════════════════════════════════════

  def agent_grid_card(assigns) do
    ~H"""
    <.card
      phx-click="navigate"
      phx-value-view="agents"
      phx-value-agent={@agent_id}
      class="bg-zinc-900 border-zinc-800 hover:border-zinc-700 cursor-pointer transition-all duration-200 group"
    >
      <.card_content class="p-3">
        <div class="flex items-center gap-2.5 mb-2">
          <div class={"w-8 h-8 rounded-lg flex items-center justify-center text-xs font-bold " <> avatar_bg(@meta[:state])}>
            <%= avatar_initial(@meta[:name] || @agent_id) %>
          </div>
          <div class="min-w-0 flex-1">
            <div class="text-sm font-medium text-zinc-200 truncate"><%= @meta[:name] || @agent_id %></div>
            <div class="flex items-center gap-1.5">
              <span class={"w-1.5 h-1.5 rounded-full " <> state_dot(@meta[:state]) <> if(@meta[:state] in ["online", "busy"], do: " animate-pulse-dot", else: "")}></span>
              <span class="text-[11px] text-zinc-500"><%= @meta[:state] || "unknown" %></span>
            </div>
          </div>
        </div>
        <%= if @meta[:task] do %>
          <div class="text-xs text-zinc-400 truncate mb-1.5" title={@meta[:task]}>
            <span class="text-zinc-600">→</span> <%= @meta[:task] %>
          </div>
        <% else %>
          <div class="text-xs text-zinc-600 italic mb-1.5">Idle</div>
        <% end %>
        <%= if @meta[:capabilities] && @meta[:capabilities] != [] do %>
          <div class="flex flex-wrap gap-1">
            <%= for cap <- Enum.take(List.wrap(@meta[:capabilities]), 3) do %>
              <.badge variant="outline" class="text-[10px] px-1.5 py-0.5 bg-zinc-800 text-zinc-500 border-zinc-700/50"><%= cap %></.badge>
            <% end %>
            <%= if length(List.wrap(@meta[:capabilities])) > 3 do %>
              <.badge variant="secondary" class="text-[10px] px-1.5 py-0.5 bg-zinc-800 text-zinc-500">+<%= length(List.wrap(@meta[:capabilities])) - 3 %></.badge>
            <% end %>
          </div>
        <% end %>
      </.card_content>
    </.card>
    """
  end

  # ═══════════════════════════════════════════════════════════
  # Agent Table Row (used inside SaladUI Table)
  # ═══════════════════════════════════════════════════════════

  def agent_table_row(assigns) do
    ~H"""
    <.table_row
      phx-click={JS.push("select_agent_detail", value: %{"agent-id" => @agent_id}) |> JS.exec("phx-show-sheet", to: "#agent-detail-sheet")}
      class={"cursor-pointer transition-colors duration-150 " <> if(@selected, do: "bg-amber-500/5", else: "hover:bg-zinc-800/50")}
    >
      <.table_cell>
        <div class="flex items-center gap-2.5">
          <div class={"w-8 h-8 rounded-lg flex items-center justify-center text-xs font-bold " <> avatar_bg(@meta[:state])}>
            <%= avatar_initial(@meta[:name] || @agent_id) %>
          </div>
          <div>
            <div class="text-sm font-medium text-zinc-200"><%= @meta[:name] || @agent_id %></div>
            <div class="text-[10px] text-zinc-600 font-mono truncate max-w-[140px]"><%= @agent_id %></div>
          </div>
        </div>
      </.table_cell>
      <.table_cell>
        <div class="flex items-center gap-1.5">
          <span class={"w-2 h-2 rounded-full " <> state_dot(@meta[:state]) <> if(@meta[:state] in ["online", "busy"], do: " animate-pulse-dot", else: "")}></span>
          <.badge variant="outline" class={"text-[10px] " <> state_badge(@meta[:state])}><%= @meta[:state] || "unknown" %></.badge>
        </div>
      </.table_cell>
      <.table_cell>
        <div class="flex flex-wrap gap-1">
          <%= for cap <- Enum.take(List.wrap(@meta[:capabilities] || []), 3) do %>
            <.badge variant="outline" class="text-[10px] px-1.5 py-0.5 bg-zinc-800 text-zinc-500 border-zinc-700/50"><%= cap %></.badge>
          <% end %>
          <%= if length(List.wrap(@meta[:capabilities] || [])) > 3 do %>
            <span class="text-[10px] text-zinc-600">+<%= length(List.wrap(@meta[:capabilities])) - 3 %></span>
          <% end %>
        </div>
      </.table_cell>
      <.table_cell>
        <span class="text-xs text-zinc-400 truncate block max-w-[180px]"><%= @meta[:task] || "—" %></span>
      </.table_cell>
      <.table_cell>
        <span class="text-xs text-zinc-500 font-mono"><%= format_connected_at(@meta[:connected_at]) %></span>
      </.table_cell>
      <.table_cell>
        <span class="text-xs text-zinc-400"><%= @meta[:framework] || "—" %></span>
      </.table_cell>
    </.table_row>
    """
  end

  # ═══════════════════════════════════════════════════════════
  # Activity Item
  # ═══════════════════════════════════════════════════════════

  def activity_item(assigns) do
    assigns = assign_new(assigns, :compact, fn -> false end)

    ~H"""
    <div
      class={"accent-bar pl-4 py-2 pr-3 rounded-lg hover:bg-zinc-800/40 transition-colors duration-150 cursor-pointer " <> kind_color(@activity.kind)}
      phx-click="activity_click_agent"
      phx-value-agent-id={@activity.agent_id}
    >
      <div class="flex items-start gap-2.5">
        <span class="text-[10px] text-zinc-600 whitespace-nowrap mt-0.5 font-mono">
          <%= format_time(@activity.timestamp) %>
        </span>
        <span class="text-sm mt-px"><%= kind_icon(@activity.kind) %></span>
        <div class="min-w-0 flex-1">
          <div class="flex items-center gap-2">
            <span class="text-sm font-medium text-zinc-200 hover:text-amber-400 transition-colors"><%= @activity.agent_name %></span>
            <.badge variant="secondary" class={"text-[10px] px-1.5 py-0.5 " <> kind_badge(@activity.kind)}>
              <%= @activity.kind %>
            </.badge>
          </div>
          <%= unless @compact do %>
            <div class="text-xs text-zinc-500 mt-0.5 truncate"><%= @activity.description %></div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # ═══════════════════════════════════════════════════════════
  # Quota Bar (compact, uses SaladUI Progress)
  # ═══════════════════════════════════════════════════════════

  def quota_bar(assigns) do
    pct = quota_pct(assigns.info)
    assigns = assign(assigns, :pct, pct)

    ~H"""
    <div>
      <div class="flex items-center justify-between text-xs mb-1">
        <span class="text-zinc-400 flex items-center gap-1.5">
          <%= render_icon(@icon, "w-3 h-3") %>
          <span><%= @label %></span>
        </span>
        <span class="text-zinc-500 font-mono text-[11px]">
          <span class="text-zinc-300"><%= fmt_num(@info[:used] || 0) %></span>
          <span class="text-zinc-600"> / </span>
          <span><%= fmt_limit(@info[:limit] || 0) %></span>
        </span>
      </div>
      <div class="h-1.5 bg-zinc-800 rounded-full overflow-hidden">
        <div
          class={"h-full rounded-full transition-all duration-500 " <> bar_color(@pct)}
          style={"width: #{max(@pct, 1)}%"}
        ></div>
      </div>
    </div>
    """
  end

  # ═══════════════════════════════════════════════════════════
  # Quota Card (large, SaladUI Card + Progress)
  # ═══════════════════════════════════════════════════════════

  def quota_card(assigns) do
    pct = quota_pct(assigns.info)
    assigns = assign(assigns, :pct, pct)

    ~H"""
    <.card class="bg-zinc-900 border-zinc-800">
      <.card_content class="p-4">
        <div class="flex items-center justify-between mb-3">
          <div class="flex items-center gap-3">
            <div class={"p-2 rounded-lg " <> icon_bg(@color)}>
              <%= render_icon(@icon, "w-4 h-4") %>
            </div>
            <div>
              <div class="text-sm font-medium text-zinc-200"><%= @label %></div>
              <div class="text-xs text-zinc-500">
                <%= fmt_num(@info[:used] || 0) %> of <%= fmt_limit(@info[:limit] || 0) %>
              </div>
            </div>
          </div>
          <div class={"text-xl font-bold " <> pct_color(@pct)}><%= @pct %>%</div>
        </div>
        <div class="h-2 bg-zinc-800 rounded-full overflow-hidden">
          <div
            class={"h-full rounded-full transition-all duration-500 " <> bar_color(@pct)}
            style={"width: #{max(@pct, 1)}%"}
          ></div>
        </div>
        <%= if @pct >= 80 do %>
          <div class={"mt-3 text-xs px-3 py-2 rounded-lg border " <> if(@pct >= 95, do: "bg-red-500/10 text-red-400 border-red-500/20", else: "bg-amber-500/10 text-amber-400 border-amber-500/20")}>
            <%= if @pct >= 95, do: "⚠ Critical — approaching limit", else: "ℹ High usage — monitor closely" %>
          </div>
        <% end %>
      </.card_content>
    </.card>
    """
  end

  # ═══════════════════════════════════════════════════════════
  # Nav Item (SaladUI Button variant=ghost)
  # ═══════════════════════════════════════════════════════════

  def nav_item(assigns) do
    assigns = assign_new(assigns, :badge, fn -> nil end)

    ~H"""
    <button
      phx-click="navigate"
      phx-value-view={@view}
      class={"w-full flex items-center gap-2.5 px-3 py-2 rounded-lg text-sm transition-colors duration-150 " <> if(@active, do: "bg-zinc-800 text-zinc-100", else: "text-zinc-400 hover:text-zinc-200 hover:bg-zinc-800/50")}
    >
      <span class={"w-5 flex justify-center " <> if(@active, do: "text-amber-400", else: "")}>
        <%= render_icon(@icon, "w-4 h-4") %>
      </span>
      <span class="flex-1 text-left font-medium"><%= @label %></span>
      <%= if @badge do %>
        <.badge variant="secondary" class="text-[10px] px-1.5 py-0.5 bg-zinc-700 text-zinc-400 font-mono"><%= @badge %></.badge>
      <% end %>
    </button>
    """
  end

  # ═══════════════════════════════════════════════════════════
  # Message Bubble
  # ═══════════════════════════════════════════════════════════

  def message_bubble(assigns) do
    is_self = get_in(assigns.msg, ["from", "agent_id"]) == "dashboard"
    assigns = assign(assigns, :is_self, is_self)

    ~H"""
    <div class={"flex mb-3 " <> if(@is_self, do: "justify-end", else: "justify-start")}>
      <.card class={"max-w-[70%] " <> if(@is_self, do: "bg-amber-500/10 border-amber-500/20 rounded-br-sm", else: "bg-zinc-800 border-zinc-700 rounded-bl-sm")}>
        <.card_content class="px-3.5 py-2.5">
          <div class="flex items-center gap-2 mb-0.5">
            <span class={"text-[11px] font-medium " <> if(@is_self, do: "text-amber-400", else: "text-zinc-400")}>
              <%= get_in(@msg, ["from", "name"]) || get_in(@msg, ["from", "agent_id"]) || "unknown" %>
            </span>
            <span class="text-[10px] text-zinc-600 font-mono"><%= format_time(@msg["timestamp"]) %></span>
          </div>
          <p class="text-sm text-zinc-200 leading-relaxed">
            <%= get_in(@msg, ["message", "text"]) || inspect(@msg["message"]) %>
          </p>
        </.card_content>
      </.card>
    </div>
    """
  end

  # ═══════════════════════════════════════════════════════════
  # Toast
  # ═══════════════════════════════════════════════════════════

  def toast(assigns) do
    ~H"""
    <div class="fixed bottom-4 right-4 z-[100] pointer-events-none">
      <.card
        class={"pointer-events-auto max-w-sm animate-slide-in-right cursor-pointer " <> toast_bg(@type)}
        phx-click="clear_toast"
        role="alert"
      >
        <.card_content class="flex items-center gap-3 px-4 py-3">
          <span><%= toast_icon(@type) %></span>
          <span class="text-sm text-zinc-200 flex-1"><%= @message %></span>
          <span class="text-zinc-500 hover:text-zinc-300 transition-colors text-xs">✕</span>
        </.card_content>
      </.card>
    </div>
    """
  end

  defp toast_bg(:success), do: "border-green-500/30 bg-green-500/10"
  defp toast_bg(:error), do: "border-red-500/30 bg-red-500/10"
  defp toast_bg(:warning), do: "border-amber-500/30 bg-amber-500/10"
  defp toast_bg(_), do: "border-blue-500/30 bg-blue-500/10"

  defp toast_icon(:success), do: "✓"
  defp toast_icon(:error), do: "✕"
  defp toast_icon(:warning), do: "⚠"
  defp toast_icon(_), do: "ℹ"

  # ═══════════════════════════════════════════════════════════
  # Empty State
  # ═══════════════════════════════════════════════════════════

  def empty_state(assigns) do
    assigns = assign_new(assigns, :icon, fn -> "◇" end)
    assigns = assign_new(assigns, :subtitle, fn -> nil end)

    ~H"""
    <div class="flex flex-col items-center justify-center py-12 text-center">
      <div class="w-14 h-14 rounded-2xl bg-zinc-800/80 border border-zinc-700/50 flex items-center justify-center mb-4 text-zinc-500">
        <%= render_icon(@icon, "w-6 h-6") %>
      </div>
      <p class="font-medium text-zinc-400"><%= @message %></p>
      <%= if @subtitle do %>
        <p class="text-sm mt-1 max-w-xs text-zinc-500"><%= @subtitle %></p>
      <% end %>
    </div>
    """
  end

  # ═══════════════════════════════════════════════════════════
  # Skeleton (SaladUI Skeleton)
  # ═══════════════════════════════════════════════════════════

  def skeleton_card(assigns) do
    ~H"""
    <.card class="bg-zinc-900 border-zinc-800">
      <.card_content class="p-4 space-y-3">
        <div class="flex items-center gap-3">
          <.skeleton class="w-10 h-10 rounded-lg" />
          <div class="flex-1 space-y-2">
            <.skeleton class="h-4 w-2/5" />
            <.skeleton class="h-3 w-3/5" />
          </div>
        </div>
      </.card_content>
    </.card>
    """
  end

  def skeleton_rows(assigns) do
    assigns = assign_new(assigns, :count, fn -> 3 end)

    ~H"""
    <div class="space-y-2">
      <%= for _i <- 1..@count do %>
        <div class="flex items-center gap-3 py-2">
          <.skeleton class="w-3 h-3 rounded-full" />
          <div class="flex-1 space-y-1.5">
            <.skeleton class="h-3 w-1/3" />
            <.skeleton class="h-2.5 w-1/4" />
          </div>
          <.skeleton class="h-6 w-16 rounded-full" />
        </div>
      <% end %>
    </div>
    """
  end

  # ═══════════════════════════════════════════════════════════
  # Command Palette
  # ═══════════════════════════════════════════════════════════

  def command_palette(assigns) do
    ~H"""
    <%= if @open do %>
      <%!-- Backdrop --%>
      <div class="fixed inset-0 z-[60] bg-black/50 backdrop-blur-sm" phx-click="toggle_command_palette"></div>

      <%!-- Palette --%>
      <div class="fixed inset-0 z-[60] flex items-start justify-center pt-[15vh]">
        <.card class="w-full max-w-lg shadow-2xl border-zinc-700 bg-zinc-900 overflow-hidden animate-fade-in">
          <.card_content class="p-0">
            <%!-- Search --%>
            <div class="flex items-center gap-3 px-4 py-3 border-b border-zinc-800">
              <Icons.search class="w-5 h-5 text-zinc-500 shrink-0" />
              <input
                type="text"
                value={@query}
                phx-keyup="cmd_search"
                placeholder="Search agents, actions..."
                autofocus
                class="flex-1 bg-transparent text-sm text-zinc-100 placeholder:text-zinc-500 focus:outline-none"
              />
              <kbd class="px-1.5 py-0.5 text-[10px] rounded bg-zinc-800 border border-zinc-700 text-zinc-500">ESC</kbd>
            </div>

            <%!-- Results --%>
            <div class="max-h-[50vh] overflow-y-auto py-2">
              <%!-- Navigation --%>
              <div class="px-4 py-1.5 text-xs font-semibold uppercase tracking-wider text-zinc-500">Navigate</div>
              <%= for {view, label, icon} <- [{"dashboard", "Dashboard", :layout_dashboard}, {"agents", "Agents", :bot}, {"activity", "Activity", :activity}, {"messaging", "Messaging", :message_square}, {"quotas", "Quotas", :gauge}, {"settings", "Settings", :settings}] do %>
                <%= if @query == "" || String.contains?(String.downcase(label), String.downcase(@query)) do %>
                  <button
                    phx-click="cmd_navigate"
                    phx-value-view={view}
                    class="w-full flex items-center gap-3 px-4 py-2.5 text-left hover:bg-zinc-800 transition-colors"
                  >
                    <span class="text-zinc-500"><%= render_icon(icon, "w-4 h-4") %></span>
                    <span class="text-sm font-medium text-zinc-200"><%= label %></span>
                  </button>
                <% end %>
              <% end %>

              <%!-- Agents --%>
              <%= if @agents != %{} do %>
                <.separator class="my-1" />
                <div class="px-4 py-1.5 text-xs font-semibold uppercase tracking-wider text-zinc-500">Agents</div>
                <%= for {agent_id, meta} <- Enum.take(filter_agents_cmd(@agents, @query), 6) do %>
                  <button
                    phx-click="cmd_go_agent"
                    phx-value-agent={agent_id}
                    class="w-full flex items-center gap-3 px-4 py-2.5 text-left hover:bg-zinc-800 transition-colors"
                  >
                    <span class={"w-2 h-2 rounded-full " <> state_dot(meta[:state])}></span>
                    <div class="flex-1 min-w-0">
                      <div class="text-sm font-medium text-zinc-200"><%= meta[:name] || agent_id %></div>
                      <div class="text-xs text-zinc-500 truncate"><%= meta[:task] || meta[:state] || "idle" %></div>
                    </div>
                  </button>
                <% end %>
              <% end %>
            </div>

            <%!-- Footer --%>
            <div class="flex items-center gap-4 px-4 py-2 border-t border-zinc-800 text-xs text-zinc-500">
              <span>↑↓ Navigate</span>
              <span>↵ Select</span>
              <span>esc Close</span>
            </div>
          </.card_content>
        </.card>
      </div>
    <% end %>
    """
  end

  defp filter_agents_cmd(agents, ""), do: Enum.take(agents, 6)
  defp filter_agents_cmd(agents, query) do
    q = String.downcase(query)
    agents
    |> Enum.filter(fn {id, m} ->
      String.contains?(String.downcase(id), q) ||
      String.contains?(String.downcase(m[:name] || ""), q)
    end)
    |> Enum.take(6)
  end

  # ═══════════════════════════════════════════════════════════
  # Shared Helpers
  # ═══════════════════════════════════════════════════════════

  def avatar_initial(nil), do: "?"
  def avatar_initial(""), do: "?"
  def avatar_initial(name), do: name |> String.trim() |> String.first() |> String.upcase()

  def avatar_bg("online"), do: "bg-green-500/15 border border-green-500/25 text-green-400"
  def avatar_bg("busy"), do: "bg-amber-500/15 border border-amber-500/25 text-amber-400"
  def avatar_bg("away"), do: "bg-zinc-700 border border-zinc-600 text-zinc-400"
  def avatar_bg("offline"), do: "bg-red-500/15 border border-red-500/25 text-red-400"
  def avatar_bg(_), do: "bg-zinc-800 border border-zinc-700 text-zinc-500"

  def state_dot("online"), do: "bg-green-400"
  def state_dot("busy"), do: "bg-amber-400"
  def state_dot("away"), do: "bg-zinc-500"
  def state_dot("offline"), do: "bg-red-400"
  def state_dot(_), do: "bg-zinc-600"

  def state_dot_color("online"), do: "#4ade80"
  def state_dot_color("busy"), do: "#fbbf24"
  def state_dot_color("away"), do: "#71717a"
  def state_dot_color("offline"), do: "#f87171"
  def state_dot_color(_), do: "#52525b"

  def state_text("online"), do: "text-green-400"
  def state_text("busy"), do: "text-amber-400"
  def state_text("away"), do: "text-zinc-400"
  def state_text("offline"), do: "text-red-400"
  def state_text(_), do: "text-zinc-500"

  def state_badge("online"), do: "bg-green-500/15 text-green-400 border-green-500/20"
  def state_badge("busy"), do: "bg-amber-500/15 text-amber-400 border-amber-500/20"
  def state_badge("away"), do: "bg-zinc-700 text-zinc-400 border-zinc-600"
  def state_badge("offline"), do: "bg-red-500/15 text-red-400 border-red-500/20"
  def state_badge(_), do: "bg-zinc-700 text-zinc-400 border-zinc-600"

  def kind_icon("task_started"), do: "🚀"
  def kind_icon("task_progress"), do: "⏳"
  def kind_icon("task_completed"), do: "✅"
  def kind_icon("task_failed"), do: "❌"
  def kind_icon("discovery"), do: "💡"
  def kind_icon("question"), do: "❓"
  def kind_icon("alert"), do: "🚨"
  def kind_icon("join"), do: "→"
  def kind_icon("leave"), do: "←"
  def kind_icon(_), do: "•"

  def kind_color("task_completed"), do: "text-green-400"
  def kind_color("task_started"), do: "text-blue-400"
  def kind_color("task_progress"), do: "text-cyan-400"
  def kind_color("task_failed"), do: "text-red-400"
  def kind_color("discovery"), do: "text-purple-400"
  def kind_color("question"), do: "text-amber-400"
  def kind_color("alert"), do: "text-red-400"
  def kind_color("join"), do: "text-green-400"
  def kind_color("leave"), do: "text-zinc-500"
  def kind_color(_), do: "text-zinc-500"

  def kind_badge("task_completed"), do: "bg-green-500/15 text-green-400"
  def kind_badge("task_started"), do: "bg-blue-500/15 text-blue-400"
  def kind_badge("task_progress"), do: "bg-cyan-500/15 text-cyan-400"
  def kind_badge("task_failed"), do: "bg-red-500/15 text-red-400"
  def kind_badge("discovery"), do: "bg-purple-500/15 text-purple-400"
  def kind_badge("question"), do: "bg-amber-500/15 text-amber-400"
  def kind_badge("alert"), do: "bg-red-500/15 text-red-400"
  def kind_badge("join"), do: "bg-green-500/15 text-green-400"
  def kind_badge("leave"), do: "bg-zinc-700 text-zinc-400"
  def kind_badge(_), do: "bg-zinc-700 text-zinc-400"

  def state_sort_order("online"), do: 0
  def state_sort_order("busy"), do: 1
  def state_sort_order("away"), do: 2
  def state_sort_order("offline"), do: 3
  def state_sort_order(_), do: 4

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

  def format_connected_at(nil), do: "—"
  def format_connected_at(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%H:%M")
      _ -> "—"
    end
  end
  def format_connected_at(_), do: "—"

  def quota_pct(%{used: _, limit: :unlimited}), do: 0
  def quota_pct(%{used: _used, limit: 0}), do: 0
  def quota_pct(%{used: used, limit: limit}) when is_integer(limit) and limit > 0 do
    min(round(used / limit * 100), 100)
  end
  def quota_pct(_), do: 0

  def fmt_num(n) when is_integer(n) and n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  def fmt_num(n) when is_integer(n) and n >= 1000, do: "#{Float.round(n / 1000, 1)}K"
  def fmt_num(n), do: "#{n}"

  def fmt_limit(:unlimited), do: "∞"
  def fmt_limit(n) when is_integer(n) and n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  def fmt_limit(n) when is_integer(n) and n >= 1000, do: "#{Float.round(n / 1000, 1)}K"
  def fmt_limit(n), do: "#{n}"

  def bar_color(pct) when pct >= 95, do: "bg-red-500 bar-glow-red"
  def bar_color(pct) when pct >= 80, do: "bg-amber-500 bar-glow-amber"
  def bar_color(_), do: "bg-green-500 bar-glow-green"

  defp pct_color(pct) when pct >= 95, do: "text-red-400"
  defp pct_color(pct) when pct >= 80, do: "text-amber-400"
  defp pct_color(_), do: "text-green-400"

  def quota_resources do
    [
      {:connected_agents, "Agents", :bot, "amber"},
      {:messages_today, "Messages", :message_square, "blue"},
      {:memory_entries, "Memory", :brain, "purple"},
      {:fleets, "Fleets", :network, "green"}
    ]
  end

  # ═══════════════════════════════════════════════════════════
  # Icon Renderer
  # ═══════════════════════════════════════════════════════════

  def render_icon(icon, class \\ "w-4 h-4")
  def render_icon(:layout_dashboard, class), do: Icons.layout_dashboard(%{class: class})
  def render_icon(:bot, class), do: Icons.bot(%{class: class})
  def render_icon(:activity, class), do: Icons.activity(%{class: class})
  def render_icon(:message_square, class), do: Icons.message_square(%{class: class})
  def render_icon(:gauge, class), do: Icons.gauge(%{class: class})
  def render_icon(:settings, class), do: Icons.settings(%{class: class})
  def render_icon(:zap, class), do: Icons.zap(%{class: class})
  def render_icon(:search, class), do: Icons.search(%{class: class})
  def render_icon(:users, class), do: Icons.users(%{class: class})
  def render_icon(:brain, class), do: Icons.brain(%{class: class})
  def render_icon(:database, class), do: Icons.database(%{class: class})
  def render_icon(:network, class), do: Icons.network(%{class: class})
  def render_icon(:layers, class), do: Icons.layers(%{class: class})
  def render_icon(:send, class), do: Icons.send(%{class: class})
  def render_icon(:shield, class), do: Icons.shield(%{class: class})
  def render_icon(:globe, class), do: Icons.globe(%{class: class})
  def render_icon(:inbox, class), do: Icons.inbox(%{class: class})
  def render_icon(:wifi, class), do: Icons.wifi(%{class: class})
  def render_icon(:plug, class), do: Icons.plug(%{class: class})
  def render_icon(:clock, class), do: Icons.clock(%{class: class})
  def render_icon(:bar_chart, class), do: Icons.bar_chart(%{class: class})
  def render_icon(:radio, class), do: Icons.radio(%{class: class})
  def render_icon(:x, class), do: Icons.x(%{class: class})
  def render_icon(:pencil, class), do: Icons.pencil(%{class: class})
  def render_icon(:trash, class), do: Icons.trash(%{class: class})
  def render_icon(:copy, class), do: Icons.copy(%{class: class})
  def render_icon(:log_out, class), do: Icons.log_out(%{class: class})
  def render_icon(:hard_drive, class), do: Icons.hard_drive(%{class: class})
  def render_icon(:credit_card, class), do: Icons.credit_card(%{class: class})
  def render_icon(:kanban, class), do: Icons.kanban(%{class: class})
  def render_icon(_, _class), do: nil
end
