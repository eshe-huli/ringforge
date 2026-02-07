defmodule Hub.Live.WebhooksLive do
  @moduledoc """
  Webhook management dashboard page.

  Allows tenants to create, edit, delete, and test outbound webhooks.
  Shows delivery logs with status indicators.
  """
  use Phoenix.LiveView
  use SaladUI

  alias Hub.Webhooks
  alias Hub.Schemas.Webhook
  alias Hub.Live.Icons

  @valid_events Webhook.valid_events()

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
      webhooks = Webhooks.list(tenant)

      {:ok, assign(socket,
        tenant_id: tenant_id,
        tenant: tenant,
        webhooks: webhooks,
        selected_webhook: nil,
        deliveries: [],
        show_form: false,
        editing: nil,
        form_url: "",
        form_description: "",
        form_events: [],
        form_fleet_id: nil,
        created_secret: nil,
        toast: nil
      )}
    end
  end

  # ══════════════════════════════════════════════════════════
  # Events
  # ══════════════════════════════════════════════════════════

  @impl true
  def handle_event("back_to_dashboard", _, socket) do
    {:noreply, redirect(socket, to: "/dashboard")}
  end

  def handle_event("new_webhook", _, socket) do
    {:noreply, assign(socket,
      show_form: true,
      editing: nil,
      form_url: "",
      form_description: "",
      form_events: [],
      form_fleet_id: nil,
      created_secret: nil
    )}
  end

  def handle_event("edit_webhook", %{"id" => id}, socket) do
    case find_webhook(socket.assigns.webhooks, id) do
      nil -> {:noreply, socket}
      wh ->
        {:noreply, assign(socket,
          show_form: true,
          editing: wh,
          form_url: wh.url,
          form_description: wh.description || "",
          form_events: wh.events,
          form_fleet_id: wh.fleet_id,
          created_secret: nil
        )}
    end
  end

  def handle_event("cancel_form", _, socket) do
    {:noreply, assign(socket, show_form: false, editing: nil, created_secret: nil)}
  end

  def handle_event("update_url", %{"value" => v}, socket), do: {:noreply, assign(socket, form_url: v)}
  def handle_event("update_description", %{"value" => v}, socket), do: {:noreply, assign(socket, form_description: v)}

  def handle_event("toggle_event", %{"event" => event}, socket) do
    events = socket.assigns.form_events
    events = if event in events, do: List.delete(events, event), else: [event | events]
    {:noreply, assign(socket, form_events: events)}
  end

  def handle_event("save_webhook", _, socket) do
    tenant = socket.assigns.tenant

    attrs = %{
      url: String.trim(socket.assigns.form_url),
      description: String.trim(socket.assigns.form_description),
      events: socket.assigns.form_events,
      fleet_id: socket.assigns.form_fleet_id
    }

    result =
      if socket.assigns.editing do
        Webhooks.update(socket.assigns.editing.id, tenant, attrs)
      else
        Webhooks.create(tenant, attrs)
      end

    case result do
      {:ok, webhook} ->
        webhooks = Webhooks.list(tenant)
        new_assigns = %{
          webhooks: webhooks,
          show_form: false,
          editing: nil,
          toast: {:success, if(socket.assigns.editing, do: "Webhook updated", else: "Webhook created")}
        }

        # Show secret only on creation
        new_assigns =
          if socket.assigns.editing do
            Map.put(new_assigns, :created_secret, nil)
          else
            Map.put(new_assigns, :created_secret, webhook.secret)
            |> Map.put(:show_form, true)
          end

        Process.send_after(self(), :clear_toast, 4_000)
        {:noreply, assign(socket, Map.to_list(new_assigns))}

      {:error, :plan_not_allowed} ->
        Process.send_after(self(), :clear_toast, 4_000)
        {:noreply, assign(socket, toast: {:error, "Webhooks not available on free plan. Upgrade to Pro or higher."})}

      {:error, :webhook_limit_reached} ->
        Process.send_after(self(), :clear_toast, 4_000)
        {:noreply, assign(socket, toast: {:error, "Webhook limit reached for your plan."})}

      {:error, %Ecto.Changeset{} = cs} ->
        errors = Ecto.Changeset.traverse_errors(cs, fn {msg, _} -> msg end)
                 |> Enum.map_join(". ", fn {f, msgs} -> "#{f}: #{Enum.join(msgs, ", ")}" end)
        Process.send_after(self(), :clear_toast, 6_000)
        {:noreply, assign(socket, toast: {:error, errors})}
    end
  end

  def handle_event("delete_webhook", %{"id" => id}, socket) do
    tenant = socket.assigns.tenant

    case Webhooks.delete(id, tenant) do
      {:ok, _} ->
        webhooks = Webhooks.list(tenant)
        Process.send_after(self(), :clear_toast, 4_000)
        {:noreply, assign(socket,
          webhooks: webhooks,
          selected_webhook: nil,
          deliveries: [],
          toast: {:success, "Webhook deleted"}
        )}

      {:error, :not_found} ->
        {:noreply, assign(socket, toast: {:error, "Webhook not found"})}
    end
  end

  def handle_event("toggle_webhook", %{"id" => id}, socket) do
    tenant = socket.assigns.tenant
    wh = find_webhook(socket.assigns.webhooks, id)

    if wh do
      case Webhooks.update(id, tenant, %{active: !wh.active}) do
        {:ok, _} ->
          webhooks = Webhooks.list(tenant)
          {:noreply, assign(socket, webhooks: webhooks)}

        _ ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("select_webhook", %{"id" => id}, socket) do
    tenant = socket.assigns.tenant

    case Webhooks.get(id, tenant) do
      {:ok, webhook} ->
        {:noreply, assign(socket,
          selected_webhook: webhook,
          deliveries: webhook.deliveries
        )}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("test_webhook", %{"id" => id}, socket) do
    tenant = socket.assigns.tenant

    case Webhooks.get(id, tenant) do
      {:ok, webhook} ->
        Hub.WebhookDispatcher.dispatch(
          "test.ping",
          %{"message" => "Test webhook delivery from RingForge", "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()},
          webhook.fleet_id
        )

        Process.send_after(self(), {:refresh_deliveries, id}, 2_000)
        Process.send_after(self(), :clear_toast, 4_000)
        {:noreply, assign(socket, toast: {:success, "Test event dispatched"})}

      _ ->
        {:noreply, assign(socket, toast: {:error, "Webhook not found"})}
    end
  end

  def handle_event("dismiss_secret", _, socket) do
    {:noreply, assign(socket, created_secret: nil, show_form: false)}
  end

  def handle_event("clear_toast", _, socket), do: {:noreply, assign(socket, toast: nil)}

  @impl true
  def handle_info(:clear_toast, socket), do: {:noreply, assign(socket, toast: nil)}

  def handle_info({:refresh_deliveries, id}, socket) do
    tenant = socket.assigns.tenant

    case Webhooks.get(id, tenant) do
      {:ok, webhook} ->
        {:noreply, assign(socket, selected_webhook: webhook, deliveries: webhook.deliveries)}

      _ ->
        {:noreply, socket}
    end
  end

  # ══════════════════════════════════════════════════════════
  # Render
  # ══════════════════════════════════════════════════════════

  @impl true
  def render(assigns) do
    assigns = assign(assigns, valid_events: @valid_events)

    ~H"""
    <div class="min-h-screen bg-zinc-950 text-zinc-100">
      <%!-- Toast --%>
      <%= if @toast do %>
        <div class={"fixed top-4 right-4 z-50 px-4 py-3 rounded-lg shadow-lg text-sm font-medium animate-fade-in " <>
          case elem(@toast, 0) do
            :success -> "bg-green-500/15 border border-green-500/25 text-green-400"
            :error -> "bg-red-500/15 border border-red-500/25 text-red-400"
            _ -> "bg-zinc-800 border border-zinc-700 text-zinc-300"
          end}>
          <%= elem(@toast, 1) %>
        </div>
      <% end %>

      <%!-- Header --%>
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
            <span class="text-zinc-600 mx-1">/</span>
            <span class="text-sm text-zinc-400">Webhooks</span>
          </div>
        </div>
      </header>

      <div class="max-w-5xl mx-auto p-6 space-y-6">
        <%!-- Title bar --%>
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-xl font-semibold text-zinc-100">Webhooks</h1>
            <p class="text-sm text-zinc-500 mt-1">Receive event notifications at your HTTP endpoints</p>
          </div>
          <button
            phx-click="new_webhook"
            class="flex items-center gap-2 px-3 py-2 rounded-lg bg-amber-500 hover:bg-amber-400 text-zinc-950 text-sm font-semibold transition-colors"
          >
            <Icons.plus class="w-4 h-4" /> Add Webhook
          </button>
        </div>

        <%!-- Secret display after creation --%>
        <%= if @created_secret do %>
          <div class="bg-amber-500/10 border border-amber-500/25 rounded-lg p-4 space-y-2 animate-fade-in">
            <div class="flex items-center gap-2 text-amber-400 text-sm font-medium">
              <Icons.key class="w-4 h-4" />
              <span>Webhook Secret — copy it now, it won't be shown again</span>
            </div>
            <code class="block bg-zinc-900 rounded px-3 py-2 text-sm font-mono text-zinc-200 select-all break-all">
              <%= @created_secret %>
            </code>
            <button phx-click="dismiss_secret" class="text-xs text-amber-400 hover:text-amber-300 underline">
              I've saved the secret
            </button>
          </div>
        <% end %>

        <%!-- Form --%>
        <%= if @show_form && is_nil(@created_secret) do %>
          <div class="bg-zinc-900 border border-zinc-800 rounded-lg p-6 space-y-4 animate-fade-in">
            <h3 class="text-sm font-semibold text-zinc-200">
              <%= if @editing, do: "Edit Webhook", else: "New Webhook" %>
            </h3>

            <div>
              <label class="text-xs text-zinc-400 mb-1.5 block font-medium">Endpoint URL (HTTPS only)</label>
              <input
                type="url"
                value={@form_url}
                phx-keyup="update_url"
                placeholder="https://example.com/webhook"
                class="w-full bg-zinc-950 border border-zinc-700 rounded-lg px-3 py-2 text-sm text-zinc-100 placeholder:text-zinc-600 focus:border-amber-500/50 focus:outline-none"
              />
            </div>

            <div>
              <label class="text-xs text-zinc-400 mb-1.5 block font-medium">Description (optional)</label>
              <input
                type="text"
                value={@form_description}
                phx-keyup="update_description"
                placeholder="Production event handler"
                class="w-full bg-zinc-950 border border-zinc-700 rounded-lg px-3 py-2 text-sm text-zinc-100 placeholder:text-zinc-600 focus:border-amber-500/50 focus:outline-none"
              />
            </div>

            <div>
              <label class="text-xs text-zinc-400 mb-2 block font-medium">Events to subscribe</label>
              <div class="grid grid-cols-2 sm:grid-cols-3 gap-2">
                <%= for event <- @valid_events do %>
                  <label class={"flex items-center gap-2 px-3 py-2 rounded-lg border cursor-pointer text-sm transition-colors " <>
                    if(event in @form_events,
                      do: "border-amber-500/40 bg-amber-500/10 text-amber-300",
                      else: "border-zinc-800 bg-zinc-950 text-zinc-500 hover:border-zinc-700")}>
                    <input
                      type="checkbox"
                      checked={event in @form_events}
                      phx-click="toggle_event"
                      phx-value-event={event}
                      class="hidden"
                    />
                    <span class={"w-3 h-3 rounded border flex items-center justify-center " <>
                      if(event in @form_events,
                        do: "border-amber-400 bg-amber-500",
                        else: "border-zinc-600")}>
                      <%= if event in @form_events do %>
                        <Icons.check class="w-2 h-2 text-zinc-950" />
                      <% end %>
                    </span>
                    <span class="truncate"><%= event %></span>
                  </label>
                <% end %>
              </div>
            </div>

            <div class="flex items-center gap-3 pt-2">
              <button
                phx-click="save_webhook"
                class="px-4 py-2 rounded-lg bg-amber-500 hover:bg-amber-400 text-zinc-950 text-sm font-semibold transition-colors"
              >
                <%= if @editing, do: "Update", else: "Create Webhook" %>
              </button>
              <button
                phx-click="cancel_form"
                class="px-4 py-2 rounded-lg border border-zinc-700 text-zinc-400 hover:text-zinc-200 text-sm transition-colors"
              >
                Cancel
              </button>
            </div>
          </div>
        <% end %>

        <%!-- Webhook list --%>
        <div class="space-y-3">
          <%= if @webhooks == [] do %>
            <div class="bg-zinc-900 border border-zinc-800 rounded-lg p-12 text-center">
              <div class="w-12 h-12 rounded-full bg-zinc-800 flex items-center justify-center mx-auto mb-3">
                <Icons.webhook class="w-6 h-6 text-zinc-500" />
              </div>
              <p class="text-sm text-zinc-400 mb-1">No webhooks configured</p>
              <p class="text-xs text-zinc-600">Create a webhook to receive event notifications</p>
            </div>
          <% else %>
            <%= for wh <- @webhooks do %>
              <div class={"bg-zinc-900 border rounded-lg overflow-hidden transition-colors " <>
                if(@selected_webhook && @selected_webhook.id == wh.id,
                  do: "border-amber-500/30",
                  else: "border-zinc-800")}>
                <div class="flex items-center justify-between p-4">
                  <div class="flex items-center gap-3 min-w-0 flex-1 cursor-pointer" phx-click="select_webhook" phx-value-id={wh.id}>
                    <span class={"w-2.5 h-2.5 rounded-full flex-shrink-0 " <> if(wh.active, do: "bg-green-400", else: "bg-zinc-600")}></span>
                    <div class="min-w-0">
                      <div class="text-sm font-medium text-zinc-200 truncate"><%= wh.url %></div>
                      <div class="text-xs text-zinc-500 mt-0.5">
                        <%= if wh.description, do: wh.description, else: "#{length(wh.events)} event(s)" %>
                      </div>
                    </div>
                  </div>
                  <div class="flex items-center gap-2 flex-shrink-0 ml-4">
                    <button phx-click="test_webhook" phx-value-id={wh.id} title="Send test event"
                      class="p-1.5 rounded text-zinc-500 hover:text-amber-400 hover:bg-zinc-800 transition-colors">
                      <Icons.play class="w-4 h-4" />
                    </button>
                    <button phx-click="toggle_webhook" phx-value-id={wh.id} title={if(wh.active, do: "Disable", else: "Enable")}
                      class={"p-1.5 rounded hover:bg-zinc-800 transition-colors " <> if(wh.active, do: "text-green-400", else: "text-zinc-600")}>
                      <Icons.power class="w-4 h-4" />
                    </button>
                    <button phx-click="edit_webhook" phx-value-id={wh.id} title="Edit"
                      class="p-1.5 rounded text-zinc-500 hover:text-zinc-200 hover:bg-zinc-800 transition-colors">
                      <Icons.settings class="w-4 h-4" />
                    </button>
                    <button phx-click="delete_webhook" phx-value-id={wh.id} title="Delete"
                      data-confirm="Delete this webhook? This cannot be undone."
                      class="p-1.5 rounded text-zinc-500 hover:text-red-400 hover:bg-zinc-800 transition-colors">
                      <Icons.trash class="w-4 h-4" />
                    </button>
                  </div>
                </div>

                <%!-- Event tags --%>
                <div class="px-4 pb-3 flex flex-wrap gap-1">
                  <%= for ev <- wh.events do %>
                    <span class="px-2 py-0.5 rounded-full bg-zinc-800 text-[10px] text-zinc-400 font-medium"><%= ev %></span>
                  <% end %>
                </div>
              </div>
            <% end %>
          <% end %>
        </div>

        <%!-- Delivery log for selected webhook --%>
        <%= if @selected_webhook do %>
          <div class="bg-zinc-900 border border-zinc-800 rounded-lg overflow-hidden">
            <div class="px-4 py-3 border-b border-zinc-800 flex items-center justify-between">
              <h3 class="text-sm font-semibold text-zinc-200">
                Delivery Log — <span class="text-zinc-400 font-normal truncate"><%= @selected_webhook.url %></span>
              </h3>
              <button phx-click="select_webhook" phx-value-id={@selected_webhook.id} class="text-xs text-amber-400 hover:text-amber-300">
                Refresh
              </button>
            </div>

            <%= if @deliveries == [] do %>
              <div class="p-8 text-center">
                <p class="text-sm text-zinc-500">No deliveries yet</p>
                <p class="text-xs text-zinc-600 mt-1">Send a test event to see delivery logs here</p>
              </div>
            <% else %>
              <div class="divide-y divide-zinc-800">
                <%= for d <- @deliveries do %>
                  <div class="px-4 py-2.5 flex items-center gap-4 text-sm">
                    <span class={"w-2 h-2 rounded-full flex-shrink-0 " <>
                      case d.status do
                        "success" -> "bg-green-400"
                        "failed" -> "bg-red-400"
                        "pending" -> "bg-amber-400 animate-pulse"
                        _ -> "bg-zinc-600"
                      end}></span>
                    <span class="text-zinc-300 w-40 truncate"><%= d.event_type %></span>
                    <span class={"w-16 text-center rounded px-1.5 py-0.5 text-xs font-medium " <>
                      case d.status do
                        "success" -> "bg-green-500/10 text-green-400"
                        "failed" -> "bg-red-500/10 text-red-400"
                        "pending" -> "bg-amber-500/10 text-amber-400"
                        _ -> "bg-zinc-800 text-zinc-400"
                      end}>
                      <%= d.status %>
                    </span>
                    <span class="text-zinc-500 w-12 text-center">#<%= d.attempt %></span>
                    <span class="text-zinc-500 w-12 text-center">
                      <%= if d.response_status, do: to_string(d.response_status), else: "—" %>
                    </span>
                    <span class="text-zinc-600 text-xs flex-1 text-right">
                      <%= Calendar.strftime(d.delivered_at, "%H:%M:%S %b %d") %>
                    </span>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # ── Helpers ────────────────────────────────────────────────

  defp find_webhook(webhooks, id) do
    Enum.find(webhooks, &(&1.id == id))
  end
end
