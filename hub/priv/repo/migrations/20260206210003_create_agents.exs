defmodule Hub.Repo.Migrations.CreateAgents do
  use Ecto.Migration

  def change do
    create table(:agents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :fleet_id, references(:fleets, type: :binary_id, on_delete: :nilify_all), null: false
      add :agent_id, :string, null: false
      add :name, :string
      add :public_key, :binary
      add :framework, :string
      add :capabilities, :jsonb, default: "[]"
      add :last_seen_at, :utc_datetime
      add :registered_via_key_id, references(:api_keys, type: :binary_id, on_delete: :nilify_all)

      timestamps()
    end

    create unique_index(:agents, [:agent_id])
    create index(:agents, [:tenant_id])
    create index(:agents, [:fleet_id])
  end
end
