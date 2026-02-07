defmodule Hub.Live.ProvisioningLive do
  @moduledoc """
  Cloud agent provisioning dashboard.

  Two-tab interface:
  - Credentials: manage cloud provider API credentials
  - Agents: provision, monitor, and destroy cloud-hosted agents

  Uses SaladUI components, zinc dark theme with amber accents.
  """
  use Phoenix.LiveView
  use SaladUI

  alias Hub.Provisioning
  alias Hub.Providers.Provider
  alias Hub.Live.Icons

  # Provider/template constants available for validation
  # @valid_providers Hub.Schemas.ProviderCredential.valid_providers()
  # @valid_templates Hub.Schemas.ProvisionedAgent.valid_templates()

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
      import Ecto.Query, only: [from: 2]
      fleet = Hub.Repo.one(from f in Hub.Auth.Fleet, where: f.tenant_id == ^tenant_id, limit: 1)

      if connected?(socket) do
        Phoenix.PubSub.subscribe(Hub.PubSub, "provisioning:#{tenant_id}")
      end

      credentials = Provisioning.list_credentials(tenant_id)
      agents = Provisioning.list_agents(tenant_id)
      total_cost = Provisioning.total_monthly_cost(tenant_id)

      {:ok, assign(socket,
        tenant_id: tenant_id,
        tenant: tenant,
        fleet_id: fleet && fleet.id,
        fleet_name: fleet && fleet.name,
        tab: "agents",
        credentials: credentials,
        agents: agents,
        total_cost: total_cost,
        templates: Provisioning.get_templates(),
        # Credential form
        show_cred_form: false,
        cred_provider: "hetzner",
        cred_name: "",
        cred_fields: %{},
        # Provision form
        show_provision_form: false,
        prov_credential_id: nil,
        prov_name: "",
        prov_region: "",
        prov_size: "",
        prov_template: "openclaw",
        prov_regions: [],
        prov_sizes: [],
        prov_loading: false,
        # State
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

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, tab: tab)}
  end

  # ── Credential form ────────────────────────────────────────

  def handle_event("show_cred_form", _, socket) do
    {:noreply, assign(socket,
      show_cred_form: true,
      cred_provider: "hetzner",
      cred_name: "",
      cred_fields: %{}
    )}
  end

  def handle_event("close_cred_form", _, socket) do
    {:noreply, assign(socket, show_cred_form: false)}
  end

  def handle_event("cred_set_provider", %{"provider" => provider}, socket) do
    {:noreply, assign(socket, cred_provider: provider, cred_fields: %{})}
  end

  def handle_event("cred_set_name", %{"value" => value}, socket) do
    {:noreply, assign(socket, cred_name: value)}
  end

  def handle_event("cred_set_field", %{"field" => field, "value" => value}, socket) do
    fields = Map.put(socket.assigns.cred_fields, field, value)
    {:noreply, assign(socket, cred_fields: fields)}
  end

  def handle_event("save_credential", _, socket) do
    attrs = %{
      provider: socket.assigns.cred_provider,
      name: socket.assigns.cred_name,
      credentials: socket.assigns.cred_fields
    }

    case Provisioning.save_credentials(socket.assigns.tenant_id, attrs) do
      {:ok, _cred} ->
        credentials = Provisioning.list_credentials(socket.assigns.tenant_id)
        Process.send_after(self(), :clear_toast, 4_000)
        {:noreply, assign(socket,
          credentials: credentials,
          show_cred_form: false,
          toast: {:success, "Credential saved"}
        )}

      {:error, _changeset} ->
        Process.send_after(self(), :clear_toast, 4_000)
        {:noreply, assign(socket, toast: {:error, "Failed to save credential"})}
    end
  end

  def handle_event("delete_credential", %{"id" => id}, socket) do
    case Provisioning.delete_credentials(id, socket.assigns.tenant_id) do
      {:ok, _} ->
        credentials = Provisioning.list_credentials(socket.assigns.tenant_id)
        Process.send_after(self(), :clear_toast, 4_000)
        {:noreply, assign(socket, credentials: credentials, toast: {:success, "Credential deleted"})}

      {:error, :credentials_in_use} ->
        Process.send_after(self(), :clear_toast, 4_000)
        {:noreply, assign(socket, toast: {:error, "Credential is in use by active agents"})}

      {:error, _} ->
        Process.send_after(self(), :clear_toast, 4_000)
        {:noreply, assign(socket, toast: {:error, "Failed to delete credential"})}
    end
  end

  # ── Provision form ────────────────────────────────────────

  def handle_event("show_provision_form", _, socket) do
    {:noreply, assign(socket,
      show_provision_form: true,
      prov_credential_id: nil,
      prov_name: "",
      prov_region: "",
      prov_size: "",
      prov_template: "openclaw",
      prov_regions: [],
      prov_sizes: [],
      prov_loading: false
    )}
  end

  def handle_event("close_provision_form", _, socket) do
    {:noreply, assign(socket, show_provision_form: false)}
  end

  def handle_event("prov_set_credential", %{"value" => credential_id}, socket) do
    # Load regions/sizes for the selected credential's provider
    cred = Enum.find(socket.assigns.credentials, &(&1.id == credential_id))
    if cred do
      provider_mod = Provider.module_for(cred.provider)
      regions = case provider_mod.list_regions(%{}) do
        {:ok, r} -> r
        _ -> []
      end
      sizes = case provider_mod.list_sizes(%{}) do
        {:ok, s} -> s
        _ -> []
      end
      {:noreply, assign(socket,
        prov_credential_id: credential_id,
        prov_regions: regions,
        prov_sizes: sizes,
        prov_region: "",
        prov_size: ""
      )}
    else
      {:noreply, assign(socket, prov_credential_id: nil)}
    end
  end

  def handle_event("prov_set_name", %{"value" => value}, socket) do
    {:noreply, assign(socket, prov_name: value)}
  end

  def handle_event("prov_set_region", %{"value" => value}, socket) do
    {:noreply, assign(socket, prov_region: value)}
  end

  def handle_event("prov_set_size", %{"value" => value}, socket) do
    # Look up cost
    {:noreply, assign(socket, prov_size: value)}
  end

  def handle_event("prov_set_template", %{"value" => value}, socket) do
    {:noreply, assign(socket, prov_template: value)}
  end

  def handle_event("provision_agent", _, socket) do
    cost = Enum.find(socket.assigns.prov_sizes, &(&1.id == socket.assigns.prov_size))
    cost_cents = if cost, do: cost.monthly_cost_cents, else: 0

    opts = %{
      "name" => socket.assigns.prov_name,
      "region" => socket.assigns.prov_region,
      "size" => socket.assigns.prov_size,
      "template" => socket.assigns.prov_template,
      "monthly_cost_cents" => cost_cents
    }

    case Provisioning.provision_agent(
      socket.assigns.tenant_id,
      socket.assigns.fleet_id,
      socket.assigns.prov_credential_id,
      opts
    ) do
      {:ok, _agent} ->
        agents = Provisioning.list_agents(socket.assigns.tenant_id)
        total_cost = Provisioning.total_monthly_cost(socket.assigns.tenant_id)
        Process.send_after(self(), :clear_toast, 4_000)
        {:noreply, assign(socket,
          agents: agents,
          total_cost: total_cost,
          show_provision_form: false,
          toast: {:success, "Agent provisioning started"}
        )}

      {:error, :rate_limited} ->
        Process.send_after(self(), :clear_toast, 4_000)
        {:noreply, assign(socket, toast: {:error, "Rate limited — max 5 concurrent provisions"})}

      {:error, _} ->
        Process.send_after(self(), :clear_toast, 4_000)
        {:noreply, assign(socket, toast: {:error, "Failed to start provisioning"})}
    end
  end

  # ── Agent actions ──────────────────────────────────────────

  def handle_event("destroy_agent", %{"id" => id}, socket) do
    case Provisioning.destroy_agent(id, socket.assigns.tenant_id) do
      {:ok, _} ->
        agents = Provisioning.list_agents(socket.assigns.tenant_id)
        total_cost = Provisioning.total_monthly_cost(socket.assigns.tenant_id)
        Process.send_after(self(), :clear_toast, 4_000)
        {:noreply, assign(socket, agents: agents, total_cost: total_cost, toast: {:success, "Agent destruction started"})}

      {:error, _} ->
        Process.send_after(self(), :clear_toast, 4_000)
        {:noreply, assign(socket, toast: {:error, "Failed to destroy agent"})}
    end
  end

  def handle_event("refresh_agents", _, socket) do
    agents = Provisioning.list_agents(socket.assigns.tenant_id)
    total_cost = Provisioning.total_monthly_cost(socket.assigns.tenant_id)
    {:noreply, assign(socket, agents: agents, total_cost: total_cost)}
  end

  def handle_event("clear_toast", _, socket), do: {:noreply, assign(socket, toast: nil)}

  # ══════════════════════════════════════════════════════════
  # PubSub
  # ══════════════════════════════════════════════════════════

  @impl true
  def handle_info({:provisioned_agent_updated, _payload}, socket) do
    agents = Provisioning.list_agents(socket.assigns.tenant_id)
    total_cost = Provisioning.total_monthly_cost(socket.assigns.tenant_id)
    {:noreply, assign(socket, agents: agents, total_cost: total_cost)}
  end

  def handle_info(:clear_toast, socket), do: {:noreply, assign(socket, toast: nil)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  # ══════════════════════════════════════════════════════════
  # Render
  # ══════════════════════════════════════════════════════════

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-zinc-950 bg-grid bg-radial-glow">
      <%!-- Toast --%>
      <%= if @toast do %>
        <div class={"fixed top-4 right-4 z-50 animate-fade-in-up flex items-center gap-2 px-4 py-3 rounded-lg border text-sm " <>
          case elem(@toast, 0) do
            :success -> "bg-green-500/10 border-green-500/20 text-green-400"
            :error -> "bg-red-500/10 border-red-500/20 text-red-400"
            _ -> "bg-zinc-800 border-zinc-700 text-zinc-300"
          end}>
          <span><%= elem(@toast, 1) %></span>
          <button phx-click="clear_toast" class="ml-2 text-zinc-500 hover:text-zinc-300">
            <Icons.x class="w-3 h-3" />
          </button>
        </div>
      <% end %>

      <%!-- Header --%>
      <header class="border-b border-zinc-800 bg-zinc-950 sticky top-0 z-40">
        <div class="max-w-7xl mx-auto px-6 h-14 flex items-center justify-between">
          <div class="flex items-center gap-3">
            <.button variant="ghost" size="icon" phx-click="back_to_dashboard" class="h-8 w-8 text-zinc-400 hover:text-zinc-200">
              <Icons.arrow_left class="w-4 h-4" />
            </.button>
            <div class="flex items-center gap-2">
              <div class="w-7 h-7 rounded-lg bg-amber-500/15 border border-amber-500/25 flex items-center justify-center text-amber-400">
                <Icons.cloud class="w-3.5 h-3.5" />
              </div>
              <span class="text-sm font-semibold text-zinc-200">Cloud Provisioning</span>
            </div>
          </div>

          <div class="flex items-center gap-3">
            <div class="flex items-center gap-2 text-xs text-zinc-400">
              <Icons.dollar_sign class="w-3.5 h-3.5" />
              <span>Est. Monthly: <span class="text-amber-400 font-medium">$<%= format_cost(@total_cost) %></span></span>
            </div>
            <.button variant="outline" size="sm" phx-click="refresh_agents" class="text-xs h-8 border-zinc-800 text-zinc-400 hover:text-zinc-200">
              <Icons.refresh_cw class="w-3 h-3 mr-1" /> Refresh
            </.button>
          </div>
        </div>
      </header>

      <div class="max-w-7xl mx-auto px-6 py-6">
        <%!-- Tabs --%>
        <div class="flex border-b border-zinc-800 mb-6">
          <button
            phx-click="switch_tab" phx-value-tab="agents"
            class={"pb-3 px-4 text-sm font-medium border-b-2 transition-colors " <>
              if(@tab == "agents",
                do: "border-amber-400 text-amber-400",
                else: "border-transparent text-zinc-500 hover:text-zinc-300")}
          >
            <Icons.server class="w-3.5 h-3.5 inline mr-1.5" />
            Agents
            <span class="ml-1.5 px-1.5 py-0.5 rounded-full bg-zinc-800 text-[10px] text-zinc-400"><%= length(@agents) %></span>
          </button>
          <button
            phx-click="switch_tab" phx-value-tab="credentials"
            class={"pb-3 px-4 text-sm font-medium border-b-2 transition-colors " <>
              if(@tab == "credentials",
                do: "border-amber-400 text-amber-400",
                else: "border-transparent text-zinc-500 hover:text-zinc-300")}
          >
            <Icons.key class="w-3.5 h-3.5 inline mr-1.5" />
            Credentials
            <span class="ml-1.5 px-1.5 py-0.5 rounded-full bg-zinc-800 text-[10px] text-zinc-400"><%= length(@credentials) %></span>
          </button>
        </div>

        <%!-- Tab content --%>
        <%= if @tab == "agents" do %>
          <%= render_agents_tab(assigns) %>
        <% else %>
          <%= render_credentials_tab(assigns) %>
        <% end %>
      </div>

      <%!-- Credential Form Modal --%>
      <%= if @show_cred_form do %>
        <%= render_cred_form(assigns) %>
      <% end %>

      <%!-- Provision Form Modal --%>
      <%= if @show_provision_form do %>
        <%= render_provision_form(assigns) %>
      <% end %>
    </div>
    """
  end

  # ══════════════════════════════════════════════════════════
  # Agents Tab
  # ══════════════════════════════════════════════════════════

  defp render_agents_tab(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="flex items-center justify-between">
        <div>
          <h3 class="text-sm font-medium text-zinc-200">Provisioned Agents</h3>
          <p class="text-xs text-zinc-500 mt-0.5">Cloud-hosted agents managed by RingForge</p>
        </div>
        <.button phx-click="show_provision_form" class="bg-amber-500 hover:bg-amber-400 text-zinc-950 font-semibold text-xs h-8 px-3"
          disabled={length(@credentials) == 0}>
          <Icons.plus class="w-3 h-3 mr-1" /> Provision Agent
        </.button>
      </div>

      <%= if length(@credentials) == 0 do %>
        <.card class="bg-zinc-900 border-zinc-800">
          <.card_content class="p-8 text-center">
            <Icons.key class="w-8 h-8 text-zinc-600 mx-auto mb-3" />
            <p class="text-sm text-zinc-400">No provider credentials configured</p>
            <p class="text-xs text-zinc-600 mt-1">Add credentials first to provision agents</p>
            <.button variant="outline" phx-click="switch_tab" phx-value-tab="credentials" class="mt-4 text-xs border-amber-500/30 text-amber-400 hover:bg-amber-500/10">
              <Icons.plus class="w-3 h-3 mr-1" /> Add Credentials
            </.button>
          </.card_content>
        </.card>
      <% else %>
        <%= if @agents == [] do %>
          <.card class="bg-zinc-900 border-zinc-800">
            <.card_content class="p-8 text-center">
              <Icons.server class="w-8 h-8 text-zinc-600 mx-auto mb-3" />
              <p class="text-sm text-zinc-400">No agents provisioned yet</p>
              <p class="text-xs text-zinc-600 mt-1">Provision your first cloud agent</p>
            </.card_content>
          </.card>
        <% else %>
          <div class="grid gap-3">
            <%= for agent <- @agents do %>
              <.card class="bg-zinc-900 border-zinc-800 hover:border-zinc-700 transition-colors">
                <.card_content class="p-4">
                  <div class="flex items-center justify-between">
                    <div class="flex items-center gap-3">
                      <div class={"w-9 h-9 rounded-lg flex items-center justify-center " <> status_bg(agent.status)}>
                        <Icons.server class="w-4 h-4" />
                      </div>
                      <div>
                        <div class="text-sm font-medium text-zinc-200"><%= agent.name %></div>
                        <div class="flex items-center gap-2 mt-0.5">
                          <span class="text-[10px] text-zinc-500"><%= provider_label(agent.provider) %></span>
                          <span class="text-zinc-700">·</span>
                          <span class="text-[10px] text-zinc-500"><%= agent.region %></span>
                          <span class="text-zinc-700">·</span>
                          <span class="text-[10px] text-zinc-500"><%= agent.size %></span>
                        </div>
                      </div>
                    </div>

                    <div class="flex items-center gap-3">
                      <%!-- IP address --%>
                      <%= if agent.ip_address do %>
                        <code class="text-[11px] text-zinc-400 bg-zinc-800 px-2 py-0.5 rounded font-mono"><%= agent.ip_address %></code>
                      <% end %>

                      <%!-- Status badge --%>
                      <.badge variant="outline" class={status_badge_class(agent.status)}>
                        <%= if agent.status == "provisioning" do %>
                          <Icons.loader class="w-2.5 h-2.5 mr-1 animate-spin" />
                        <% end %>
                        <%= agent.status %>
                      </.badge>

                      <%!-- Cost --%>
                      <span class="text-[11px] text-zinc-500">$<%= format_cost(agent.monthly_cost_cents) %>/mo</span>

                      <%!-- Actions --%>
                      <%= if agent.status not in ["destroyed"] do %>
                        <.button variant="ghost" size="icon" phx-click="destroy_agent" phx-value-id={agent.id}
                          class="h-7 w-7 text-zinc-500 hover:text-red-400" title="Destroy agent"
                          data-confirm="Destroy this agent? This cannot be undone.">
                          <Icons.trash class="w-3.5 h-3.5" />
                        </.button>
                      <% end %>
                    </div>
                  </div>

                  <%!-- Error message --%>
                  <%= if agent.error_message && agent.status == "error" do %>
                    <div class="mt-2 text-xs text-red-400 bg-red-500/5 border border-red-500/10 rounded px-3 py-1.5">
                      <Icons.alert_triangle class="w-3 h-3 inline mr-1" />
                      <%= String.slice(agent.error_message || "", 0, 200) %>
                    </div>
                  <% end %>
                </.card_content>
              </.card>
            <% end %>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  # ══════════════════════════════════════════════════════════
  # Credentials Tab
  # ══════════════════════════════════════════════════════════

  defp render_credentials_tab(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="flex items-center justify-between">
        <div>
          <h3 class="text-sm font-medium text-zinc-200">Provider Credentials</h3>
          <p class="text-xs text-zinc-500 mt-0.5">API keys for cloud providers — encrypted at rest</p>
        </div>
        <.button phx-click="show_cred_form" class="bg-amber-500 hover:bg-amber-400 text-zinc-950 font-semibold text-xs h-8 px-3">
          <Icons.plus class="w-3 h-3 mr-1" /> Add Credential
        </.button>
      </div>

      <%= if @credentials == [] do %>
        <.card class="bg-zinc-900 border-zinc-800">
          <.card_content class="p-8 text-center">
            <Icons.shield class="w-8 h-8 text-zinc-600 mx-auto mb-3" />
            <p class="text-sm text-zinc-400">No provider credentials yet</p>
            <p class="text-xs text-zinc-600 mt-1">Add your first cloud provider API key</p>
          </.card_content>
        </.card>
      <% else %>
        <div class="grid gap-3">
          <%= for cred <- @credentials do %>
            <.card class="bg-zinc-900 border-zinc-800">
              <.card_content class="p-4">
                <div class="flex items-center justify-between">
                  <div class="flex items-center gap-3">
                    <div class="w-9 h-9 rounded-lg bg-zinc-800 border border-zinc-700 flex items-center justify-center text-zinc-400">
                      <Icons.key class="w-4 h-4" />
                    </div>
                    <div>
                      <div class="text-sm font-medium text-zinc-200"><%= cred.name %></div>
                      <div class="flex items-center gap-2 mt-0.5">
                        <.badge variant="outline" class="text-[10px] border-zinc-700 text-zinc-400"><%= provider_label(cred.provider) %></.badge>
                        <span class="text-[10px] text-zinc-600">
                          <%= if cred.active, do: "Active", else: "Inactive" %>
                        </span>
                      </div>
                    </div>
                  </div>

                  <div class="flex items-center gap-2">
                    <%!-- Masked credentials preview --%>
                    <div class="hidden sm:flex items-center gap-1.5">
                      <%= for {key, val} <- Map.to_list(cred.credentials) |> Enum.take(2) do %>
                        <code class="text-[10px] text-zinc-500 bg-zinc-800 px-1.5 py-0.5 rounded">
                          <%= key %>: <%= val %>
                        </code>
                      <% end %>
                    </div>

                    <.button variant="ghost" size="icon" phx-click="delete_credential" phx-value-id={cred.id}
                      class="h-7 w-7 text-zinc-500 hover:text-red-400" title="Delete credential"
                      data-confirm="Delete this credential?">
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
    """
  end

  # ══════════════════════════════════════════════════════════
  # Credential Form Modal
  # ══════════════════════════════════════════════════════════

  defp render_cred_form(assigns) do
    ~H"""
    <div class="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-sm" phx-click="close_cred_form">
      <div class="w-full max-w-lg mx-4 animate-fade-in-up" phx-click-away="close_cred_form">
        <.card class="bg-zinc-900 border-zinc-800 shadow-2xl">
          <.card_header>
            <.card_title class="text-zinc-100 flex items-center gap-2">
              <Icons.key class="w-4 h-4 text-amber-400" />
              Add Provider Credential
            </.card_title>
            <.card_description>Encrypted at rest with AES-256-GCM</.card_description>
          </.card_header>
          <.card_content class="space-y-4">
            <%!-- Provider select --%>
            <div>
              <label class="text-xs text-zinc-400 mb-1.5 block font-medium">Provider</label>
              <div class="grid grid-cols-4 gap-2">
                <%= for provider <- ["hetzner", "digitalocean", "contabo", "aws"] do %>
                  <button
                    phx-click="cred_set_provider" phx-value-provider={provider}
                    class={"flex flex-col items-center gap-1 p-3 rounded-lg border text-xs font-medium transition-all " <>
                      if(@cred_provider == provider,
                        do: "border-amber-500/50 bg-amber-500/10 text-amber-400",
                        else: "border-zinc-800 bg-zinc-800/50 text-zinc-400 hover:border-zinc-700")}
                  >
                    <Icons.cloud class="w-4 h-4" />
                    <%= provider_label(provider) %>
                  </button>
                <% end %>
              </div>
            </div>

            <%!-- Name --%>
            <div>
              <label class="text-xs text-zinc-400 mb-1.5 block font-medium">Name</label>
              <.input
                type="text"
                value={@cred_name}
                phx-keyup="cred_set_name"
                placeholder="e.g., Production Hetzner"
                class="bg-zinc-950 border-zinc-700 text-zinc-100"
              />
            </div>

            <%!-- Provider-specific fields --%>
            <%= render_provider_fields(assigns) %>
          </.card_content>
          <div class="p-6 pt-0 flex justify-end gap-2">
            <.button variant="outline" phx-click="close_cred_form" class="border-zinc-700 text-zinc-400">Cancel</.button>
            <.button phx-click="save_credential" class="bg-amber-500 hover:bg-amber-400 text-zinc-950 font-semibold"
              disabled={@cred_name == "" || map_size(@cred_fields) == 0}>
              <Icons.shield class="w-3.5 h-3.5 mr-1" /> Save Credential
            </.button>
          </div>
        </.card>
      </div>
    </div>
    """
  end

  defp render_provider_fields(%{cred_provider: "hetzner"} = assigns) do
    ~H"""
    <div>
      <label class="text-xs text-zinc-400 mb-1.5 block font-medium">API Token</label>
      <.input
        type="password"
        value={@cred_fields["api_token"] || ""}
        phx-keyup="cred_set_field" phx-value-field="api_token"
        placeholder="Hetzner Cloud API token"
        class="bg-zinc-950 border-zinc-700 text-zinc-100 font-mono"
      />
      <p class="text-[10px] text-zinc-600 mt-1">From Hetzner Cloud Console → Security → API Tokens</p>
    </div>
    """
  end

  defp render_provider_fields(%{cred_provider: "digitalocean"} = assigns) do
    ~H"""
    <div>
      <label class="text-xs text-zinc-400 mb-1.5 block font-medium">API Token</label>
      <.input
        type="password"
        value={@cred_fields["api_token"] || ""}
        phx-keyup="cred_set_field" phx-value-field="api_token"
        placeholder="DigitalOcean personal access token"
        class="bg-zinc-950 border-zinc-700 text-zinc-100 font-mono"
      />
      <p class="text-[10px] text-zinc-600 mt-1">From DigitalOcean → API → Personal Access Tokens</p>
    </div>
    """
  end

  defp render_provider_fields(%{cred_provider: "contabo"} = assigns) do
    ~H"""
    <div class="space-y-3">
      <div>
        <label class="text-xs text-zinc-400 mb-1.5 block font-medium">Client ID</label>
        <.input type="text" value={@cred_fields["client_id"] || ""} phx-keyup="cred_set_field" phx-value-field="client_id" placeholder="OAuth2 client ID" class="bg-zinc-950 border-zinc-700 text-zinc-100 font-mono" />
      </div>
      <div>
        <label class="text-xs text-zinc-400 mb-1.5 block font-medium">Client Secret</label>
        <.input type="password" value={@cred_fields["client_secret"] || ""} phx-keyup="cred_set_field" phx-value-field="client_secret" placeholder="OAuth2 client secret" class="bg-zinc-950 border-zinc-700 text-zinc-100 font-mono" />
      </div>
      <div>
        <label class="text-xs text-zinc-400 mb-1.5 block font-medium">API User</label>
        <.input type="text" value={@cred_fields["api_user"] || ""} phx-keyup="cred_set_field" phx-value-field="api_user" placeholder="API username" class="bg-zinc-950 border-zinc-700 text-zinc-100 font-mono" />
      </div>
      <div>
        <label class="text-xs text-zinc-400 mb-1.5 block font-medium">API Password</label>
        <.input type="password" value={@cred_fields["api_password"] || ""} phx-keyup="cred_set_field" phx-value-field="api_password" placeholder="API password" class="bg-zinc-950 border-zinc-700 text-zinc-100 font-mono" />
      </div>
    </div>
    """
  end

  defp render_provider_fields(%{cred_provider: "aws"} = assigns) do
    ~H"""
    <div class="space-y-3">
      <div>
        <label class="text-xs text-zinc-400 mb-1.5 block font-medium">Access Key ID</label>
        <.input type="text" value={@cred_fields["access_key_id"] || ""} phx-keyup="cred_set_field" phx-value-field="access_key_id" placeholder="AKIA..." class="bg-zinc-950 border-zinc-700 text-zinc-100 font-mono" />
      </div>
      <div>
        <label class="text-xs text-zinc-400 mb-1.5 block font-medium">Secret Access Key</label>
        <.input type="password" value={@cred_fields["secret_access_key"] || ""} phx-keyup="cred_set_field" phx-value-field="secret_access_key" placeholder="Secret access key" class="bg-zinc-950 border-zinc-700 text-zinc-100 font-mono" />
      </div>
    </div>
    """
  end

  defp render_provider_fields(assigns) do
    ~H"""
    <div class="text-xs text-zinc-500">Select a provider above</div>
    """
  end

  # ══════════════════════════════════════════════════════════
  # Provision Form Modal
  # ══════════════════════════════════════════════════════════

  defp render_provision_form(assigns) do
    selected_size = Enum.find(assigns.prov_sizes, &(&1.id == assigns.prov_size))
    assigns = assign(assigns, :selected_size_cost, if(selected_size, do: selected_size.monthly_cost_cents, else: 0))

    ~H"""
    <div class="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-sm" phx-click="close_provision_form">
      <div class="w-full max-w-lg mx-4 animate-fade-in-up max-h-[85vh] overflow-y-auto" phx-click-away="close_provision_form">
        <.card class="bg-zinc-900 border-zinc-800 shadow-2xl">
          <.card_header>
            <.card_title class="text-zinc-100 flex items-center gap-2">
              <Icons.server class="w-4 h-4 text-amber-400" />
              Provision Agent
            </.card_title>
            <.card_description>Deploy a new agent to the cloud</.card_description>
          </.card_header>
          <.card_content class="space-y-4">
            <%!-- Credential select --%>
            <div>
              <label class="text-xs text-zinc-400 mb-1.5 block font-medium">Provider Credential</label>
              <select
                phx-change="prov_set_credential"
                class="w-full h-9 rounded-md border border-zinc-700 bg-zinc-950 px-3 text-sm text-zinc-100 focus:border-amber-500/50 focus:ring-0"
              >
                <option value="">Select credential...</option>
                <%= for cred <- @credentials do %>
                  <option value={cred.id} selected={cred.id == @prov_credential_id}>
                    <%= cred.name %> (<%= provider_label(cred.provider) %>)
                  </option>
                <% end %>
              </select>
            </div>

            <%!-- Agent name --%>
            <div>
              <label class="text-xs text-zinc-400 mb-1.5 block font-medium">Agent Name</label>
              <.input
                type="text"
                value={@prov_name}
                phx-keyup="prov_set_name"
                placeholder="rf-worker-01"
                class="bg-zinc-950 border-zinc-700 text-zinc-100"
              />
            </div>

            <%!-- Region --%>
            <%= if @prov_regions != [] do %>
              <div>
                <label class="text-xs text-zinc-400 mb-1.5 block font-medium">Region</label>
                <select
                  phx-change="prov_set_region"
                  class="w-full h-9 rounded-md border border-zinc-700 bg-zinc-950 px-3 text-sm text-zinc-100 focus:border-amber-500/50 focus:ring-0"
                >
                  <option value="">Select region...</option>
                  <%= for region <- @prov_regions do %>
                    <option value={region.id} selected={region.id == @prov_region}><%= region.name %></option>
                  <% end %>
                </select>
              </div>
            <% end %>

            <%!-- Size / Plan --%>
            <%= if @prov_sizes != [] do %>
              <div>
                <label class="text-xs text-zinc-400 mb-1.5 block font-medium">Size / Plan</label>
                <select
                  phx-change="prov_set_size"
                  class="w-full h-9 rounded-md border border-zinc-700 bg-zinc-950 px-3 text-sm text-zinc-100 focus:border-amber-500/50 focus:ring-0"
                >
                  <option value="">Select size...</option>
                  <%= for size <- @prov_sizes do %>
                    <option value={size.id} selected={size.id == @prov_size}>
                      <%= size.name %> — $<%= format_cost(size.monthly_cost_cents) %>/mo
                    </option>
                  <% end %>
                </select>
              </div>
            <% end %>

            <%!-- Template --%>
            <div>
              <label class="text-xs text-zinc-400 mb-1.5 block font-medium">Template</label>
              <div class="grid grid-cols-3 gap-2">
                <%= for tmpl <- @templates do %>
                  <button
                    phx-click="prov_set_template" phx-value-value={tmpl.id}
                    class={"flex flex-col items-center gap-1 p-3 rounded-lg border text-xs transition-all " <>
                      if(@prov_template == tmpl.id,
                        do: "border-amber-500/50 bg-amber-500/10 text-amber-400",
                        else: "border-zinc-800 bg-zinc-800/50 text-zinc-400 hover:border-zinc-700")}
                  >
                    <Icons.package class="w-4 h-4" />
                    <span class="font-medium"><%= tmpl.name %></span>
                  </button>
                <% end %>
              </div>
            </div>

            <%!-- Cost preview --%>
            <%= if @selected_size_cost > 0 do %>
              <div class="flex items-center justify-between p-3 rounded-lg bg-zinc-800/50 border border-zinc-700/50">
                <span class="text-xs text-zinc-400">Estimated monthly cost</span>
                <span class="text-sm font-bold text-amber-400">$<%= format_cost(@selected_size_cost) %>/mo</span>
              </div>
            <% end %>
          </.card_content>
          <div class="p-6 pt-0 flex justify-end gap-2">
            <.button variant="outline" phx-click="close_provision_form" class="border-zinc-700 text-zinc-400">Cancel</.button>
            <.button phx-click="provision_agent" class="bg-amber-500 hover:bg-amber-400 text-zinc-950 font-semibold"
              disabled={@prov_credential_id == nil || @prov_name == "" || @prov_region == "" || @prov_size == ""}>
              <Icons.cloud class="w-3.5 h-3.5 mr-1" /> Provision
            </.button>
          </div>
        </.card>
      </div>
    </div>
    """
  end

  # ══════════════════════════════════════════════════════════
  # Helpers
  # ══════════════════════════════════════════════════════════

  defp format_cost(cents) when is_integer(cents) do
    dollars = cents / 100
    :erlang.float_to_binary(dollars, decimals: 2)
  end
  defp format_cost(_), do: "0.00"

  defp provider_label("hetzner"), do: "Hetzner"
  defp provider_label("digitalocean"), do: "DigitalOcean"
  defp provider_label("contabo"), do: "Contabo"
  defp provider_label("aws"), do: "AWS"
  defp provider_label(other), do: other

  defp status_bg("running"), do: "bg-green-500/15 text-green-400"
  defp status_bg("provisioning"), do: "bg-yellow-500/15 text-yellow-400"
  defp status_bg("stopped"), do: "bg-zinc-700 text-zinc-400"
  defp status_bg("error"), do: "bg-red-500/15 text-red-400"
  defp status_bg("destroyed"), do: "bg-zinc-800 text-zinc-600"
  defp status_bg(_), do: "bg-zinc-800 text-zinc-400"

  defp status_badge_class("running"), do: "border-green-500/30 bg-green-500/10 text-green-400 text-[10px]"
  defp status_badge_class("provisioning"), do: "border-yellow-500/30 bg-yellow-500/10 text-yellow-400 text-[10px]"
  defp status_badge_class("stopped"), do: "border-zinc-600 bg-zinc-800 text-zinc-400 text-[10px]"
  defp status_badge_class("error"), do: "border-red-500/30 bg-red-500/10 text-red-400 text-[10px]"
  defp status_badge_class("destroyed"), do: "border-zinc-700 bg-zinc-800 text-zinc-600 text-[10px]"
  defp status_badge_class(_), do: "border-zinc-700 bg-zinc-800 text-zinc-400 text-[10px]"
end
