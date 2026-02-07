defmodule Hub.Devices do
  @moduledoc """
  Context module for IoT/domotic device management.

  Provides CRUD operations for devices, sensor reading ingestion,
  and command dispatch. All operations are tenant-scoped.
  """

  import Ecto.Query
  require Logger

  alias Hub.Repo
  alias Hub.Schemas.Device

  # ── Registration ───────────────────────────────────────────

  @doc """
  Register a new IoT device in a fleet.

  ## Params
    - `tenant_id` — tenant UUID
    - `fleet_id` — fleet UUID
    - `attrs` — map with name, device_type, protocol, topic, metadata
  """
  def register_device(tenant_id, fleet_id, attrs) do
    params =
      attrs
      |> Map.put(:tenant_id, tenant_id)
      |> Map.put(:fleet_id, fleet_id)

    %Device{}
    |> Device.changeset(params)
    |> Repo.insert()
  end

  # ── Reading Updates ────────────────────────────────────────

  @doc """
  Update a device's sensor reading and mark it as online.

  Also stores in fleet memory with key prefix `device:{device_id}:latest`
  and broadcasts an activity event.
  """
  def update_reading(device_id, value, fleet_id \\ nil) do
    case Repo.get(Device, device_id) do
      nil ->
        {:error, :not_found}

      device ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        reading_value =
          cond do
            is_map(value) -> value
            is_number(value) -> %{"value" => value}
            is_binary(value) -> parse_reading(value)
            true -> %{"raw" => inspect(value)}
          end

        result =
          device
          |> Device.reading_changeset(%{
            last_value: reading_value,
            last_seen_at: now,
            online: true
          })
          |> Repo.update()

        case result do
          {:ok, updated} ->
            # Store in fleet memory
            fid = fleet_id || updated.fleet_id
            mem_key = "device:#{device_id}:latest"

            Task.start(fn ->
              Hub.Memory.set(fid, mem_key, %{
                "value" => reading_value,
                "author" => "device:#{device_id}",
                "tags" => ["device", "reading"]
              })
            end)

            # Broadcast activity event
            Task.start(fn ->
              bus_topic = "ringforge.#{fid}.activity"

              Hub.EventBus.publish(bus_topic, %{
                "kind" => "device.reading",
                "device_id" => device_id,
                "device_name" => updated.name,
                "value" => reading_value,
                "timestamp" => DateTime.to_iso8601(now)
              })
            end)

            {:ok, updated}

          error ->
            error
        end
    end
  end

  # ── Commands ───────────────────────────────────────────────

  @doc """
  Send a command to an actuator device.

  If the device is MQTT-connected and the MQTT bridge is running,
  publishes the command to the device's topic. Otherwise queues
  the command as an activity event.
  """
  def send_command(device_id, command) do
    case Repo.get(Device, device_id) do
      nil ->
        {:error, :not_found}

      %Device{protocol: "mqtt", topic: topic} = device when is_binary(topic) ->
        # Publish via MQTT bridge if available
        case Hub.MQTT.Bridge.publish(topic, command) do
          :ok ->
            Logger.info("[Devices] Command sent to #{device.name} on #{topic}")
            {:ok, :sent}

          {:error, :not_connected} ->
            Logger.warning("[Devices] MQTT bridge not connected, queuing command")
            queue_command(device, command)
        end

      device ->
        queue_command(device, command)
    end
  end

  # ── Queries ────────────────────────────────────────────────

  @doc "List all devices in a fleet."
  def list_devices(fleet_id) do
    Device
    |> where(fleet_id: ^fleet_id)
    |> order_by([d], desc: d.last_seen_at)
    |> Repo.all()
  end

  @doc "Get a device by ID, scoped to tenant."
  def get_device(device_id, tenant_id) do
    Device
    |> where(id: ^device_id, tenant_id: ^tenant_id)
    |> Repo.one()
  end

  @doc "Get a device by its MQTT topic within a fleet."
  def get_device_by_topic(fleet_id, topic) do
    Device
    |> where(fleet_id: ^fleet_id, topic: ^topic)
    |> Repo.one()
  end

  @doc "Mark a device as offline."
  def mark_offline(device_id) do
    case Repo.get(Device, device_id) do
      nil -> {:error, :not_found}

      device ->
        device
        |> Device.reading_changeset(%{online: false})
        |> Repo.update()
    end
  end

  @doc "Delete a device."
  def delete_device(device_id, tenant_id) do
    case get_device(device_id, tenant_id) do
      nil -> {:error, :not_found}
      device -> Repo.delete(device)
    end
  end

  # ── Private ────────────────────────────────────────────────

  defp parse_reading(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> decoded
      {:ok, decoded} -> %{"value" => decoded}
      _ ->
        case Float.parse(value) do
          {num, _} -> %{"value" => num}
          :error -> %{"raw" => value}
        end
    end
  end

  defp queue_command(device, command) do
    bus_topic = "ringforge.#{device.fleet_id}.activity"

    payload =
      cond do
        is_map(command) -> Jason.encode!(command)
        is_binary(command) -> command
        true -> inspect(command)
      end

    Task.start(fn ->
      Hub.EventBus.publish(bus_topic, %{
        "kind" => "device.command",
        "device_id" => device.id,
        "device_name" => device.name,
        "command" => payload,
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
      })
    end)

    {:ok, :queued}
  end
end
