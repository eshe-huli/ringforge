defmodule Hub.Repo.Migrations.CreateDevices do
  use Ecto.Migration

  def change do
    create table(:devices, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :fleet_id, references(:fleets, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :device_type, :string, null: false, default: "sensor"
      add :protocol, :string, null: false, default: "mqtt"
      add :topic, :string
      add :last_value, :map, default: %{}
      add :last_seen_at, :utc_datetime
      add :online, :boolean, default: false
      add :metadata, :map, default: %{}

      timestamps()
    end

    create index(:devices, [:tenant_id])
    create index(:devices, [:fleet_id])
    create index(:devices, [:tenant_id, :fleet_id])
    create unique_index(:devices, [:fleet_id, :name])
  end
end
