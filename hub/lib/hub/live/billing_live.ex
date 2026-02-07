defmodule Hub.Live.BillingLive do
  @moduledoc """
  Billing dashboard page — plan management, usage overview, and Stripe integration.

  Shows current plan, usage vs limits with progress bars, upgrade/downgrade
  options, and links to Stripe Checkout / Customer Portal.
  """
  use Phoenix.LiveView
  use SaladUI

  alias Hub.Billing
  alias Hub.Quota
  alias Hub.Live.Icons
  alias Hub.Live.Components

  @refresh_interval 10_000

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
      subscription = Billing.get_subscription(tenant_id)
      usage = Quota.get_usage(tenant_id)
      limits = Quota.get_plan_limits(plan)
      features = Quota.plan_features(plan)
      plans = Billing.plans_info()

      if connected?(socket) do
        Process.send_after(self(), :refresh_usage, @refresh_interval)
      end

      {:ok, assign(socket,
        tenant_id: tenant_id,
        tenant_name: tenant.name,
        tenant_email: tenant.email,
        plan: plan,
        subscription: subscription,
        usage: usage,
        limits: limits,
        features: features,
        plans: plans,
        toast: nil
      )}
    end
  end

  # ══════════════════════════════════════════════════════════
  # Events
  # ══════════════════════════════════════════════════════════

  @impl true
  def handle_event("upgrade", %{"plan" => plan}, socket) do
    # Redirect to checkout via the billing controller
    {:noreply, redirect(socket, to: "/billing/checkout?plan=#{plan}")}
  end

  def handle_event("manage_subscription", _, socket) do
    {:noreply, redirect(socket, to: "/billing/portal")}
  end

  def handle_event("back_to_dashboard", _, socket) do
    {:noreply, redirect(socket, to: "/dashboard")}
  end

  @impl true
  def handle_info(:refresh_usage, socket) do
    if socket.assigns[:tenant_id] do
      Process.send_after(self(), :refresh_usage, @refresh_interval)
      usage = Quota.get_usage(socket.assigns.tenant_id)
      {:noreply, assign(socket, usage: usage)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ══════════════════════════════════════════════════════════
  # Render
  # ══════════════════════════════════════════════════════════

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-zinc-950 text-zinc-100">
      <%!-- Header bar --%>
      <header class="h-12 border-b border-zinc-800 flex items-center justify-between px-6 bg-zinc-950">
        <div class="flex items-center gap-3">
          <button phx-click="back_to_dashboard" class="text-zinc-400 hover:text-zinc-200 transition-colors">
            <Icons.arrow_left class="w-4 h-4" />
          </button>
          <div class="flex items-center gap-2">
            <div class="w-7 h-7 rounded-lg bg-amber-500/15 border border-amber-500/25 flex items-center justify-center text-amber-400">
              <Icons.zap class="w-3.5 h-3.5" />
            </div>
            <span class="text-sm font-semibold text-zinc-200">Ring<span class="text-amber-400">Forge</span></span>
            <.separator orientation="vertical" class="h-4 mx-1" />
            <span class="text-xs text-zinc-500">Billing</span>
          </div>
        </div>
      </header>

      <div class="max-w-5xl mx-auto px-6 py-8 space-y-8 animate-fade-in">
        <%!-- Page title --%>
        <div>
          <h1 class="text-2xl font-bold text-zinc-100">Billing & Plan</h1>
          <p class="text-sm text-zinc-500 mt-1">Manage your subscription, view usage, and upgrade</p>
        </div>

        <%!-- Current plan card --%>
        <.card class="bg-zinc-900 border-zinc-800">
          <.card_content class="p-6">
            <div class="flex items-center justify-between">
              <div class="flex items-center gap-4">
                <div class={"w-12 h-12 rounded-xl flex items-center justify-center " <> plan_icon_bg(@plan)}>
                  <%= plan_icon(@plan) %>
                </div>
                <div>
                  <div class="flex items-center gap-2">
                    <h2 class="text-lg font-bold text-zinc-100 capitalize"><%= @plan %> Plan</h2>
                    <%= if @subscription && @subscription.status == "active" do %>
                      <.badge variant="outline" class="border-green-500/30 bg-green-500/10 text-green-400 text-[10px]">Active</.badge>
                    <% end %>
                    <%= if @subscription && @subscription.status == "past_due" do %>
                      <.badge variant="outline" class="border-red-500/30 bg-red-500/10 text-red-400 text-[10px]">Past Due</.badge>
                    <% end %>
                    <%= if @subscription && @subscription.status == "trialing" do %>
                      <.badge variant="outline" class="border-blue-500/30 bg-blue-500/10 text-blue-400 text-[10px]">Trial</.badge>
                    <% end %>
                  </div>
                  <p class="text-sm text-zinc-500">
                    <%= (@plans[@plan] || %{})[:price_label] || "Free forever" %>
                    <%= if @subscription && @subscription.current_period_end do %>
                      · Renews <%= Calendar.strftime(@subscription.current_period_end, "%b %d, %Y") %>
                    <% end %>
                  </p>
                </div>
              </div>
              <div class="flex items-center gap-2">
                <%= if @plan != "free" do %>
                  <.button variant="outline" phx-click="manage_subscription" class="border-zinc-700 text-zinc-300 hover:bg-zinc-800">
                    Manage Subscription
                  </.button>
                <% end %>
              </div>
            </div>
          </.card_content>
        </.card>

        <%!-- Usage section --%>
        <div>
          <h3 class="text-sm font-semibold text-zinc-300 mb-4">Current Usage</h3>
          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <%= for {resource, label, icon, color} <- billing_resources() do %>
              <% info = Map.get(@usage, resource, %{used: 0, limit: 0}) %>
              <Components.quota_card label={label} icon={icon} color={color} info={info} />
            <% end %>
          </div>
        </div>

        <%!-- Features --%>
        <div>
          <h3 class="text-sm font-semibold text-zinc-300 mb-4">Plan Features</h3>
          <.card class="bg-zinc-900 border-zinc-800">
            <.card_content class="p-4">
              <div class="grid grid-cols-2 md:grid-cols-3 gap-4">
                <div class="flex items-center gap-2">
                  <%= if @features.webhooks do %>
                    <Icons.check class="w-4 h-4 text-green-400" />
                  <% else %>
                    <Icons.x class="w-4 h-4 text-zinc-600" />
                  <% end %>
                  <span class="text-sm text-zinc-300">Webhooks</span>
                </div>
                <div class="flex items-center gap-2">
                  <%= if @features.audit_logs do %>
                    <Icons.check class="w-4 h-4 text-green-400" />
                  <% else %>
                    <Icons.x class="w-4 h-4 text-zinc-600" />
                  <% end %>
                  <span class="text-sm text-zinc-300">Audit Logs</span>
                </div>
                <div class="flex items-center gap-2">
                  <Icons.clock class="w-4 h-4 text-zinc-400" />
                  <span class="text-sm text-zinc-300">
                    <%= format_retention(@features.event_retention_hours) %> event retention
                  </span>
                </div>
              </div>
            </.card_content>
          </.card>
        </div>

        <%!-- Plans comparison --%>
        <div>
          <h3 class="text-sm font-semibold text-zinc-300 mb-4">Available Plans</h3>
          <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4">
            <%= for plan_key <- ["free", "pro", "scale", "enterprise"] do %>
              <% plan_info = @plans[plan_key] %>
              <% is_current = @plan == plan_key %>
              <.card class={"bg-zinc-900 border-zinc-800 transition-colors " <> if(is_current, do: "ring-1 ring-amber-500/30 border-amber-500/20", else: "hover:border-zinc-700")}>
                <.card_content class="p-5">
                  <div class="space-y-4">
                    <div>
                      <h4 class="text-base font-bold text-zinc-100"><%= plan_info.name %></h4>
                      <p class={"text-lg font-bold mt-1 " <> if(is_current, do: "text-amber-400", else: "text-zinc-300")}>
                        <%= plan_info.price_label %>
                      </p>
                    </div>

                    <.separator class="bg-zinc-800" />

                    <ul class="space-y-2 text-xs text-zinc-400">
                      <li class="flex items-center gap-2">
                        <Icons.bot class="w-3.5 h-3.5 text-zinc-500" />
                        <span><%= format_limit_val(plan_info.limits.connected_agents) %> agents</span>
                      </li>
                      <li class="flex items-center gap-2">
                        <Icons.message_square class="w-3.5 h-3.5 text-zinc-500" />
                        <span><%= format_limit_val(plan_info.limits.messages_today) %> msgs/day</span>
                      </li>
                      <li class="flex items-center gap-2">
                        <Icons.brain class="w-3.5 h-3.5 text-zinc-500" />
                        <span><%= format_limit_val(plan_info.limits.memory_entries) %> memory entries</span>
                      </li>
                      <li class="flex items-center gap-2">
                        <Icons.network class="w-3.5 h-3.5 text-zinc-500" />
                        <span><%= format_limit_val(plan_info.limits.fleets) %> fleets</span>
                      </li>
                      <li class="flex items-center gap-2">
                        <Icons.hard_drive class="w-3.5 h-3.5 text-zinc-500" />
                        <span><%= format_storage(plan_info.limits.storage_bytes) %></span>
                      </li>
                    </ul>

                    <div class="pt-2">
                      <%= cond do %>
                        <% is_current -> %>
                          <.button variant="outline" disabled class="w-full border-amber-500/30 text-amber-400 opacity-60 cursor-default">
                            Current Plan
                          </.button>
                        <% plan_key == "enterprise" -> %>
                          <.button variant="outline" class="w-full border-zinc-700 text-zinc-300 hover:bg-zinc-800">
                            Contact Sales
                          </.button>
                        <% plan_key == "free" -> %>
                          <%!-- Can't downgrade to free via button — use portal --%>
                          <.button variant="outline" disabled class="w-full border-zinc-700 text-zinc-500 opacity-50 cursor-default">
                            Free Tier
                          </.button>
                        <% true -> %>
                          <.button phx-click="upgrade" phx-value-plan={plan_key} class="w-full bg-amber-500 hover:bg-amber-400 text-zinc-950 font-semibold">
                            <%= if plan_order(plan_key) > plan_order(@plan), do: "Upgrade", else: "Switch" %>
                          </.button>
                      <% end %>
                    </div>
                  </div>
                </.card_content>
              </.card>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── Helpers ────────────────────────────────────────────────

  defp billing_resources do
    [
      {:connected_agents, "Agents", :bot, "amber"},
      {:messages_today, "Messages Today", :message_square, "blue"},
      {:memory_entries, "Memory Entries", :brain, "purple"},
      {:fleets, "Fleets", :network, "green"},
      {:storage_bytes, "File Storage", :hard_drive, "blue"}
    ]
  end

  defp plan_order("free"), do: 0
  defp plan_order("pro"), do: 1
  defp plan_order("scale"), do: 2
  defp plan_order("enterprise"), do: 3
  defp plan_order(_), do: 0

  defp plan_icon_bg("free"), do: "bg-zinc-800 text-zinc-400"
  defp plan_icon_bg("pro"), do: "bg-amber-500/15 text-amber-400"
  defp plan_icon_bg("scale"), do: "bg-blue-500/15 text-blue-400"
  defp plan_icon_bg("enterprise"), do: "bg-purple-500/15 text-purple-400"
  defp plan_icon_bg(_), do: "bg-zinc-800 text-zinc-400"

  defp plan_icon("free"), do: Icons.zap(%{class: "w-5 h-5"})
  defp plan_icon("pro"), do: Icons.zap(%{class: "w-5 h-5"})
  defp plan_icon("scale"), do: Icons.layers(%{class: "w-5 h-5"})
  defp plan_icon("enterprise"), do: Icons.shield(%{class: "w-5 h-5"})
  defp plan_icon(_), do: Icons.zap(%{class: "w-5 h-5"})

  defp format_limit_val(:unlimited), do: "Unlimited"
  defp format_limit_val(n) when is_integer(n) and n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_limit_val(n) when is_integer(n) and n >= 1_000, do: "#{Float.round(n / 1_000, 0) |> trunc}K"
  defp format_limit_val(n), do: "#{n}"

  defp format_storage(:unlimited), do: "Unlimited storage"
  defp format_storage(bytes) when is_integer(bytes) and bytes >= 1_073_741_824 do
    gb = Float.round(bytes / 1_073_741_824, 0) |> trunc()
    "#{gb} GB storage"
  end
  defp format_storage(bytes) when is_integer(bytes), do: "#{div(bytes, 1_048_576)} MB storage"
  defp format_storage(_), do: "—"

  defp format_retention(hours) when hours >= 720, do: "#{div(hours, 720)}d"
  defp format_retention(hours) when hours >= 24, do: "#{div(hours, 24)}d"
  defp format_retention(hours), do: "#{hours}h"
end
