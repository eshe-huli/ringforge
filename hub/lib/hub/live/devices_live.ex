defmodule Hub.Live.DevicesLive do
  @moduledoc """
  IoT device management dashboard page.

  Lists devices with online/offline indicators, last readings,
  command sending, and device detail view.
  """
  use Phoenix.LiveView
  use SaladUI

  alias Hub.Devices
  alias Hub.Live.Icons

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

      # Get the default fleet
      import Ecto.Query
      fleet = Hub.Repo.one(from f in Hub.Auth.Fleet, where: f.tenant_id == ^tenant_id, limit: 1)
      fleet_id = if fleet, do: fleet.id

      devices = if fleet_id, do: Devices.list_devices(fleet_id), else: []

      # Subscribe to device updates
      if fleet_id do
        Phoenix.PubSub.subscribe(Hub.PubSub, "fleet:#{fleet_id}")
      end

      {:ok, assign(socket,
        tenant_id: tenant_id,
        tenant: tenant,
        fleet_id: fleet_id,
        devices: devices,
        selected_device: nil,
        show_form: false,
        show_command: false,
        form_name: "",
        form_type: "sensor",
        form_protocol: "mqtt",
        form_topic: "",
        command_text: "",
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

  def handle_event("new_device", _, socket) do
    {:noreply, assign(socket,
      show_form: true,
      form_name: "",
      form_type: "sensor",
      form_protocol: "mqtt",
      form_topic: ""
    )}
  end

  def handle_event("cancel_form", _, socket) do
    {:noreply, assign(socket, show_form: false)}
  end

  def handle_event("update_name", %{"value" => v}, socket), do: {:noreply, assign(socket, form_name: v)}
  def handle_event("update_type", %{"value" => v}, socket), do: {:noreply, assign(socket, form_type: v)}
  def handle_event("update_protocol", %{"value" => v}, socket), do: {:noreply, assign(socket, form_protocol: v)}
  def handle_event("update_topic", %{"value" => v}, socket), do: {:noreply, assign(socket, form_topic: v)}

  def handle_event("save_device", _, socket) do
    attrs = %{
      name: socket.assigns.form_name,
      device_type: socket.assigns.form_type,
      protocol: socket.assigns.form_protocol,
      topic: socket.assigns.form_topic
    }

    case Devices.register_device(socket.assigns.tenant_id, socket.assigns.fleet_id, attrs) do
      {:ok, _device} ->
        devices = Devices.list_devices(socket.assigns.fleet_id)
        {:noreply, assign(socket, devices: devices, show_form: false, toast: "Device registered")}

      {:error, changeset} ->
        {:noreply, assign(socket, toast: "Error: #{inspect(changeset.errors)}")}
    end
  end

  def handle_event("select_device", %{"id" => id}, socket) do
    device = Enum.find(socket.assigns.devices, &(&1.id == id))
    {:noreply, assign(socket, selected_device: device, show_command: false)}
  end

  def handle_event("close_detail", _, socket) do
    {:noreply, assign(socket, selected_device: nil)}
  end

  def handle_event("show_command", _, socket) do
    {:noreply, assign(socket, show_command: true, command_text: "")}
  end

  def handle_event("update_command", %{"value" => v}, socket) do
    {:noreply, assign(socket, command_text: v)}
  end

  def handle_event("send_command", _, socket) do
    if socket.assigns.selected_device do
      case Devices.send_command(socket.assigns.selected_device.id, socket.assigns.command_text) do
        {:ok, status} ->
          {:noreply, assign(socket, show_command: false, toast: "Command #{status}")}

        {:error, reason} ->
          {:noreply, assign(socket, toast: "Command failed: #{inspect(reason)}")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("delete_device", %{"id" => id}, socket) do
    case Devices.delete_device(id, socket.assigns.tenant_id) do
      {:ok, _} ->
        devices = Devices.list_devices(socket.assigns.fleet_id)
        {:noreply, assign(socket, devices: devices, selected_device: nil, toast: "Device deleted")}

      {:error, _} ->
        {:noreply, assign(socket, toast: "Delete failed")}
    end
  end

  def handle_event("refresh", _, socket) do
    devices = Devices.list_devices(socket.assigns.fleet_id)
    {:noreply, assign(socket, devices: devices)}
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
          <h1 class="text-xl font-bold text-zinc-100">IoT Devices</h1>
          <span class="text-xs text-zinc-500"><%= length(@devices) %> devices</span>
        </div>
        <div class="flex gap-2">
          <button phx-click="refresh" class="px-3 py-1.5 bg-zinc-800 border border-zinc-700 rounded text-xs text-zinc-300 hover:bg-zinc-700">
            Refresh
          </button>
          <button phx-click="new_device" class="px-3 py-1.5 bg-amber-600 rounded text-xs text-zinc-900 font-medium hover:bg-amber-500">
            + Add Device
          </button>
        </div>
      </div>

      <!-- Toast -->
      <%= if @toast do %>
        <div phx-click="dismiss_toast" class="mb-4 p-3 bg-zinc-800 border border-zinc-700 rounded text-xs text-zinc-300 cursor-pointer">
          <%= @toast %>
        </div>
      <% end %>

      <div class="flex gap-6">
        <!-- Device List -->
        <div class={"flex-1 " <> if(@selected_device, do: "max-w-2xl", else: "")}>
          <%= if @devices == [] do %>
            <div class="text-center py-16 text-zinc-500">
              <p class="text-lg mb-2">No devices registered</p>
              <p class="text-xs">Register IoT devices to monitor sensors and control actuators</p>
            </div>
          <% else %>
            <div class="space-y-2">
              <%= for device <- @devices do %>
                <div
                  phx-click="select_device"
                  phx-value-id={device.id}
                  class={"p-4 rounded border cursor-pointer transition-colors " <>
                    if(@selected_device && @selected_device.id == device.id,
                      do: "bg-zinc-800 border-amber-600/50",
                      else: "bg-zinc-900 border-zinc-800 hover:border-zinc-700"
                    )
                  }
                >
                  <div class="flex items-center justify-between">
                    <div class="flex items-center gap-3">
                      <!-- Online indicator -->
                      <div class={"w-2 h-2 rounded-full " <> if(device.online, do: "bg-green-400 animate-pulse-dot", else: "bg-zinc-600")} />
                      <div>
                        <div class="font-medium text-zinc-200 text-sm"><%= device.name %></div>
                        <div class="text-xs text-zinc-500">
                          <%= device.device_type %> · <%= device.protocol %>
                          <%= if device.topic do %>
                            · <span class="text-zinc-400"><%= device.topic %></span>
                          <% end %>
                        </div>
                      </div>
                    </div>
                    <div class="text-right">
                      <%= if device.last_value && device.last_value != %{} do %>
                        <div class="text-xs text-amber-400 font-mono">
                          <%= format_value(device.last_value) %>
                        </div>
                      <% end %>
                      <%= if device.last_seen_at do %>
                        <div class="text-[10px] text-zinc-600">
                          <%= relative_time(device.last_seen_at) %>
                        </div>
                      <% end %>
                    </div>
                  </div>
                </div>
              <% end %>
            </div>
          <% end %>
        </div>

        <!-- Device Detail Panel -->
        <%= if @selected_device do %>
          <div class="w-96 bg-zinc-900 border border-zinc-800 rounded-lg p-5 animate-slide-in-right">
            <div class="flex items-center justify-between mb-4">
              <h2 class="font-bold text-zinc-100"><%= @selected_device.name %></h2>
              <button phx-click="close_detail" class="text-zinc-500 hover:text-zinc-300 text-lg">×</button>
            </div>

            <div class="space-y-3 text-xs">
              <div class="flex justify-between">
                <span class="text-zinc-500">Status</span>
                <span class={"font-medium " <> if(@selected_device.online, do: "text-green-400", else: "text-zinc-500")}>
                  <%= if @selected_device.online, do: "Online", else: "Offline" %>
                </span>
              </div>
              <div class="flex justify-between">
                <span class="text-zinc-500">Type</span>
                <span class="text-zinc-300"><%= @selected_device.device_type %></span>
              </div>
              <div class="flex justify-between">
                <span class="text-zinc-500">Protocol</span>
                <span class="text-zinc-300"><%= @selected_device.protocol %></span>
              </div>
              <%= if @selected_device.topic do %>
                <div class="flex justify-between">
                  <span class="text-zinc-500">Topic</span>
                  <span class="text-zinc-300 font-mono text-[11px]"><%= @selected_device.topic %></span>
                </div>
              <% end %>
              <%= if @selected_device.last_seen_at do %>
                <div class="flex justify-between">
                  <span class="text-zinc-500">Last Seen</span>
                  <span class="text-zinc-300"><%= Calendar.strftime(@selected_device.last_seen_at, "%Y-%m-%d %H:%M:%S") %></span>
                </div>
              <% end %>

              <!-- Last Value -->
              <%= if @selected_device.last_value && @selected_device.last_value != %{} do %>
                <div class="mt-4">
                  <div class="text-zinc-500 mb-2">Last Reading</div>
                  <div class="bg-zinc-800 rounded p-3 font-mono text-[11px] text-amber-400">
                    <pre class="whitespace-pre-wrap"><%= Jason.encode!(@selected_device.last_value, pretty: true) %></pre>
                  </div>
                </div>
              <% end %>

              <!-- Metadata -->
              <%= if @selected_device.metadata && @selected_device.metadata != %{} do %>
                <div class="mt-3">
                  <div class="text-zinc-500 mb-2">Metadata</div>
                  <div class="bg-zinc-800 rounded p-3 font-mono text-[11px] text-zinc-400">
                    <pre class="whitespace-pre-wrap"><%= Jason.encode!(@selected_device.metadata, pretty: true) %></pre>
                  </div>
                </div>
              <% end %>

              <!-- Commands -->
              <%= if @selected_device.device_type in ["actuator", "controller"] do %>
                <div class="mt-4 pt-3 border-t border-zinc-800">
                  <%= if @show_command do %>
                    <div class="space-y-2">
                      <textarea
                        phx-keyup="update_command"
                        rows="3"
                        placeholder="Command payload (JSON or text)..."
                        class="w-full bg-zinc-800 border border-zinc-700 rounded p-2 text-xs text-zinc-200 font-mono resize-none focus:border-amber-600 focus:outline-none"
                      ><%= @command_text %></textarea>
                      <div class="flex gap-2">
                        <button phx-click="send_command" class="flex-1 py-1.5 bg-amber-600 rounded text-xs text-zinc-900 font-medium hover:bg-amber-500">
                          Send
                        </button>
                        <button phx-click="show_command" class="py-1.5 px-3 bg-zinc-800 border border-zinc-700 rounded text-xs text-zinc-400 hover:bg-zinc-700">
                          Cancel
                        </button>
                      </div>
                    </div>
                  <% else %>
                    <button phx-click="show_command" class="w-full py-2 bg-zinc-800 border border-zinc-700 rounded text-xs text-zinc-300 hover:bg-zinc-700">
                      ⚡ Send Command
                    </button>
                  <% end %>
                </div>
              <% end %>

              <!-- Delete -->
              <div class="mt-4 pt-3 border-t border-zinc-800">
                <button
                  phx-click="delete_device"
                  phx-value-id={@selected_device.id}
                  data-confirm="Delete this device?"
                  class="w-full py-2 bg-red-900/30 border border-red-900/50 rounded text-xs text-red-400 hover:bg-red-900/50"
                >
                  Delete Device
                </button>
              </div>
            </div>
          </div>
        <% end %>
      </div>

      <!-- Register Device Form Modal -->
      <%= if @show_form do %>
        <div class="fixed inset-0 bg-black/60 z-50 flex items-center justify-center" phx-click="cancel_form">
          <div class="bg-zinc-900 border border-zinc-700 rounded-lg p-6 w-full max-w-md" phx-click-away="cancel_form">
            <h2 class="text-lg font-bold text-zinc-100 mb-4">Register Device</h2>

            <div class="space-y-4">
              <div>
                <label class="block text-xs text-zinc-400 mb-1">Name</label>
                <input
                  type="text"
                  phx-keyup="update_name"
                  value={@form_name}
                  placeholder="e.g., living-room-temp"
                  class="w-full bg-zinc-800 border border-zinc-700 rounded p-2 text-sm text-zinc-200 focus:border-amber-600 focus:outline-none"
                />
              </div>

              <div>
                <label class="block text-xs text-zinc-400 mb-1">Type</label>
                <select phx-change="update_type" class="w-full bg-zinc-800 border border-zinc-700 rounded p-2 text-sm text-zinc-200 focus:border-amber-600 focus:outline-none">
                  <option value="sensor" selected={@form_type == "sensor"}>Sensor</option>
                  <option value="actuator" selected={@form_type == "actuator"}>Actuator</option>
                  <option value="controller" selected={@form_type == "controller"}>Controller</option>
                  <option value="gateway" selected={@form_type == "gateway"}>Gateway</option>
                </select>
              </div>

              <div>
                <label class="block text-xs text-zinc-400 mb-1">Protocol</label>
                <select phx-change="update_protocol" class="w-full bg-zinc-800 border border-zinc-700 rounded p-2 text-sm text-zinc-200 focus:border-amber-600 focus:outline-none">
                  <option value="mqtt" selected={@form_protocol == "mqtt"}>MQTT</option>
                  <option value="websocket" selected={@form_protocol == "websocket"}>WebSocket</option>
                  <option value="http" selected={@form_protocol == "http"}>HTTP</option>
                </select>
              </div>

              <div>
                <label class="block text-xs text-zinc-400 mb-1">MQTT Topic</label>
                <input
                  type="text"
                  phx-keyup="update_topic"
                  value={@form_topic}
                  placeholder="e.g., home/livingroom/temperature"
                  class="w-full bg-zinc-800 border border-zinc-700 rounded p-2 text-sm text-zinc-200 font-mono focus:border-amber-600 focus:outline-none"
                />
              </div>

              <div class="flex gap-2 pt-2">
                <button phx-click="save_device" class="flex-1 py-2 bg-amber-600 rounded text-sm text-zinc-900 font-medium hover:bg-amber-500">
                  Register
                </button>
                <button phx-click="cancel_form" class="py-2 px-4 bg-zinc-800 border border-zinc-700 rounded text-sm text-zinc-400 hover:bg-zinc-700">
                  Cancel
                </button>
              </div>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # ── Helpers ────────────────────────────────────────────────

  defp format_value(value) when is_map(value) do
    case value do
      %{"value" => v} when is_number(v) -> "#{v}"
      %{"value" => v} -> "#{inspect(v)}"
      map ->
        map
        |> Enum.take(3)
        |> Enum.map(fn {k, v} -> "#{k}: #{inspect(v)}" end)
        |> Enum.join(", ")
    end
  end

  defp format_value(v), do: inspect(v)

  defp relative_time(nil), do: "never"
  defp relative_time(dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86400)}d ago"
    end
  end
end
