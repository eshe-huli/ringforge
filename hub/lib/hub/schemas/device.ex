defmodule Hub.Schemas.Device do
  @moduledoc """
  Schema for IoT/domotic devices registered in a fleet.

  Devices represent sensors, actuators, controllers, or gateways that
  communicate via MQTT, WebSocket, or HTTP. Each device is scoped to a
  tenant and fleet for multi-tenant isolation.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_device_types ~w(sensor actuator controller gateway)
  @valid_protocols ~w(mqtt websocket http)

  schema "devices" do
    field :name, :string
    field :device_type, :string, default: "sensor"
    field :protocol, :string, default: "mqtt"
    field :topic, :string
    field :last_value, :map, default: %{}
    field :last_seen_at, :utc_datetime
    field :online, :boolean, default: false
    field :metadata, :map, default: %{}

    belongs_to :tenant, Hub.Auth.Tenant
    belongs_to :fleet, Hub.Auth.Fleet

    timestamps()
  end

  @required_fields ~w(name device_type protocol)a
  @optional_fields ~w(topic last_value last_seen_at online metadata)a

  def changeset(device, attrs) do
    device
    |> cast(attrs, @required_fields ++ @optional_fields ++ [:tenant_id, :fleet_id])
    |> validate_required(@required_fields)
    |> validate_inclusion(:device_type, @valid_device_types)
    |> validate_inclusion(:protocol, @valid_protocols)
    |> validate_length(:name, max: 255)
    |> validate_length(:topic, max: 1024)
    |> foreign_key_constraint(:tenant_id)
    |> foreign_key_constraint(:fleet_id)
    |> unique_constraint([:fleet_id, :name])
  end

  def reading_changeset(device, attrs) do
    device
    |> cast(attrs, [:last_value, :last_seen_at, :online])
  end

  def valid_device_types, do: @valid_device_types
  def valid_protocols, do: @valid_protocols
end
