defmodule Hub.Live.InvitesLive do
  @moduledoc """
  Invite code management dashboard.

  Allows tenants to create, list, copy, and revoke invite codes.
  Used when the system is in invite-only registration mode.
  """
  use Phoenix.LiveView
  use SaladUI

  alias Hub.Invites
  alias Hub.Live.Icons
  alias Hub.Live.Components

  # ══════════════════════════════════════════════════════════
  # Mount
  # ══════════════════════════════════════════════════════════

  @impl true
  def mount(_params, session, socket) do
    tenant_id = session["tenant_id"]

    unless tenant_id do
      {:ok, redirect(socket, to: "/dashboard")}
    else
      invites = Invites.list_invites(tenant_id)
      mode = Invites.registration_mode()

      {:ok, assign(socket,
        tenant_id: tenant_id,
        invites: invites,
        registration_mode: mode,
        toast: nil,
        new_max_uses: "1",
        new_expires_days: ""
      )}
    end
  end

  # ══════════════════════════════════════════════════════════
  # Events
  # ══════════════════════════════════════════════════════════

  @impl true
  def handle_event("create_invite", _params, socket) do
    tenant_id = socket.assigns.tenant_id
    max_uses = parse_int(socket.assigns.new_max_uses, 1)

    expires_at =
      case parse_int(socket.assigns.new_expires_days, 0) do
        0 -> nil
        days ->
          DateTime.utc_now()
          |> DateTime.add(days * 86_400, :second)
          |> DateTime.truncate(:second)
      end

    case Invites.create_invite(tenant_id, max_uses: max_uses, expires_at: expires_at) do
      {:ok, _invite} ->
        invites = Invites.list_invites(tenant_id)
        Process.send_after(self(), :clear_toast, 4_000)
        {:noreply, assign(socket,
          invites: invites,
          toast: {:success, "Invite code created"},
          new_max_uses: "1",
          new_expires_days: ""
        )}

      {:error, _} ->
        Process.send_after(self(), :clear_toast, 4_000)
        {:noreply, assign(socket, toast: {:error, "Failed to create invite code"})}
    end
  end

  def handle_event("revoke_invite", %{"code" => code}, socket) do
    tenant_id = socket.assigns.tenant_id

    case Invites.revoke_invite(code, tenant_id) do
      {:ok, _} ->
        invites = Invites.list_invites(tenant_id)
        Process.send_after(self(), :clear_toast, 4_000)
        {:noreply, assign(socket, invites: invites, toast: {:success, "Invite code revoked"})}

      {:error, _} ->
        Process.send_after(self(), :clear_toast, 4_000)
        {:noreply, assign(socket, toast: {:error, "Failed to revoke invite code"})}
    end
  end

  def handle_event("update_max_uses", %{"value" => val}, socket) do
    {:noreply, assign(socket, new_max_uses: val)}
  end

  def handle_event("update_expires_days", %{"value" => val}, socket) do
    {:noreply, assign(socket, new_expires_days: val)}
  end

  def handle_event("back_to_dashboard", _, socket) do
    {:noreply, redirect(socket, to: "/dashboard")}
  end

  def handle_event("clear_toast", _, socket) do
    {:noreply, assign(socket, toast: nil)}
  end

  @impl true
  def handle_info(:clear_toast, socket), do: {:noreply, assign(socket, toast: nil)}
  def handle_info(_, socket), do: {:noreply, socket}

  # ══════════════════════════════════════════════════════════
  # Render
  # ══════════════════════════════════════════════════════════

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-zinc-950 text-zinc-100">
      <%!-- Toast --%>
      <%= if @toast do %>
        <Components.toast type={elem(@toast, 0)} message={elem(@toast, 1)} />
      <% end %>

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
            <span class="text-xs text-zinc-500">Invite Codes</span>
          </div>
        </div>
      </header>

      <div class="max-w-3xl mx-auto px-6 py-8 space-y-8 animate-fade-in">
        <%!-- Page title --%>
        <div>
          <h1 class="text-2xl font-bold text-zinc-100">Invite Codes</h1>
          <p class="text-sm text-zinc-500 mt-1">
            Manage registration invite codes ·
            <span class={"font-medium " <> if(@registration_mode == :invite_only, do: "text-amber-400", else: "text-green-400")}>
              <%= if @registration_mode == :invite_only, do: "Invite-only mode", else: "Open registration" %>
            </span>
          </p>
        </div>

        <%!-- Create new invite --%>
        <.card class="bg-zinc-900 border-zinc-800">
          <.card_content class="p-6">
            <h3 class="text-sm font-semibold text-zinc-300 mb-4">Create New Invite</h3>
            <div class="flex items-end gap-4">
              <div class="flex-1">
                <label class="text-xs text-zinc-400 mb-1.5 block font-medium">Max Uses</label>
                <.input
                  type="number"
                  value={@new_max_uses}
                  phx-keyup="update_max_uses"
                  min="1"
                  max="1000"
                  class="w-full bg-zinc-950 border-zinc-700 text-zinc-100"
                />
              </div>
              <div class="flex-1">
                <label class="text-xs text-zinc-400 mb-1.5 block font-medium">Expires In (days, 0=never)</label>
                <.input
                  type="number"
                  value={@new_expires_days}
                  phx-keyup="update_expires_days"
                  placeholder="0"
                  min="0"
                  class="w-full bg-zinc-950 border-zinc-700 text-zinc-100"
                />
              </div>
              <.button
                phx-click="create_invite"
                class="bg-amber-500 hover:bg-amber-400 text-zinc-950 font-semibold h-10 px-6"
              >
                <Icons.plus class="w-4 h-4 mr-2" />
                Create
              </.button>
            </div>
          </.card_content>
        </.card>

        <%!-- Invites list --%>
        <div>
          <h3 class="text-sm font-semibold text-zinc-300 mb-4">Active Codes (<%= length(@invites) %>)</h3>
          <%= if @invites == [] do %>
            <.card class="bg-zinc-900 border-zinc-800">
              <.card_content class="p-8 text-center">
                <p class="text-sm text-zinc-500">No invite codes yet</p>
              </.card_content>
            </.card>
          <% else %>
            <div class="space-y-2">
              <%= for invite <- @invites do %>
                <.card class="bg-zinc-900 border-zinc-800 hover:border-zinc-700 transition-colors">
                  <.card_content class="px-5 py-3.5">
                    <div class="flex items-center justify-between">
                      <div class="flex items-center gap-4">
                        <div class="flex items-center gap-2">
                          <code class="text-sm font-mono font-bold text-amber-400 bg-amber-500/10 px-3 py-1 rounded-lg border border-amber-500/20">
                            <%= invite.code %>
                          </code>
                          <button
                            phx-click={Phoenix.LiveView.JS.dispatch("phx:copy", detail: %{text: invite_url(invite.code)})}
                            class="text-zinc-500 hover:text-zinc-300 transition-colors"
                            title="Copy invite link"
                          >
                            <Icons.copy class="w-3.5 h-3.5" />
                          </button>
                        </div>
                        <div class="flex items-center gap-3 text-xs text-zinc-500">
                          <span><%= invite.uses %>/<%= invite.max_uses %> uses</span>
                          <.separator orientation="vertical" class="h-3" />
                          <%= if invite.expires_at do %>
                            <span class={if DateTime.compare(invite.expires_at, DateTime.utc_now()) == :lt, do: "text-red-400", else: ""}>
                              Expires <%= format_date(invite.expires_at) %>
                            </span>
                          <% else %>
                            <span>No expiry</span>
                          <% end %>
                          <.separator orientation="vertical" class="h-3" />
                          <span>Created <%= format_date(invite.inserted_at) %></span>
                        </div>
                      </div>
                      <div class="flex items-center gap-2">
                        <%= if invite.uses >= invite.max_uses do %>
                          <.badge variant="outline" class="text-[10px] border-zinc-600 text-zinc-500">Exhausted</.badge>
                        <% else %>
                          <.badge variant="outline" class="text-[10px] border-green-500/30 text-green-400">Active</.badge>
                        <% end %>
                        <.button
                          variant="ghost"
                          size="icon"
                          phx-click="revoke_invite"
                          phx-value-code={invite.code}
                          data-confirm="Revoke this invite code? This cannot be undone."
                          class="h-7 w-7 text-zinc-500 hover:text-red-400"
                        >
                          <Icons.trash class="w-3.5 h-3.5" />
                        </.button>
                      </div>
                    </div>
                  </.card_content>
                </.card>
              <% end %>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # ── Helpers ────────────────────────────────────────────────

  defp invite_url(code) do
    "#{Hub.Endpoint.url()}/dashboard?tab=register&invite=#{code}"
  end

  defp format_date(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%b %d, %Y")
  defp format_date(%DateTime{} = dt), do: Calendar.strftime(dt, "%b %d, %Y")
  defp format_date(_), do: "—"

  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} when n > 0 -> n
      _ -> default
    end
  end
  defp parse_int(_, default), do: default
end
