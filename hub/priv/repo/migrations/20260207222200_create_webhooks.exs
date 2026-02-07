defmodule Hub.Repo.Migrations.CreateWebhooks do
  use Ecto.Migration

  def change do
    create table(:webhooks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :fleet_id, references(:fleets, type: :binary_id, on_delete: :delete_all), null: true
      add :url, :string, null: false
      add :secret, :string, null: false
      add :events, {:array, :string}, null: false, default: []
      add :active, :boolean, default: true, null: false
      add :description, :string, null: true

      timestamps()
    end

    create index(:webhooks, [:tenant_id])
    create index(:webhooks, [:tenant_id, :fleet_id])

    create table(:webhook_deliveries, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :webhook_id, references(:webhooks, type: :binary_id, on_delete: :delete_all), null: false
      add :event_type, :string, null: false
      add :payload, :map, null: false, default: %{}
      add :response_status, :integer, null: true
      add :response_body, :text, null: true
      add :attempt, :integer, null: false, default: 1
      add :delivered_at, :utc_datetime, null: false
      add :next_retry_at, :utc_datetime, null: true
      add :status, :string, null: false, default: "pending"
    end

    create index(:webhook_deliveries, [:webhook_id])
    create index(:webhook_deliveries, [:webhook_id, :status])
    create index(:webhook_deliveries, [:next_retry_at], where: "status = 'pending'")
  end
end
