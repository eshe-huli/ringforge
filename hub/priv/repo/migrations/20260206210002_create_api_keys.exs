defmodule Hub.Repo.Migrations.CreateApiKeys do
  use Ecto.Migration

  def change do
    create table(:api_keys, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :fleet_id, references(:fleets, type: :binary_id, on_delete: :nilify_all)
      add :key_hash, :string, null: false
      add :key_prefix, :string, null: false
      add :type, :string, null: false
      add :permissions, :jsonb, default: "[]"
      add :expires_at, :utc_datetime
      add :revoked_at, :utc_datetime

      timestamps()
    end

    create unique_index(:api_keys, [:key_hash])
    create index(:api_keys, [:tenant_id])
    create index(:api_keys, [:key_prefix])
  end
end
