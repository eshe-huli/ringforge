defmodule Hub.Repo.Migrations.CreateAuditLogs do
  use Ecto.Migration

  def change do
    create table(:audit_logs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :action, :string, null: false
      add :actor_type, :string, null: false
      add :actor_id, :string, null: false
      add :target_type, :string
      add :target_id, :string
      add :ip_address, :string
      add :metadata, :map, default: %{}

      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create index(:audit_logs, [:tenant_id])
    create index(:audit_logs, [:action])
    create index(:audit_logs, [:actor_type, :actor_id])
    create index(:audit_logs, [:target_type, :target_id])
    create index(:audit_logs, [:inserted_at])
    create index(:audit_logs, [:tenant_id, :inserted_at])
  end
end
