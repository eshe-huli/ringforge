defmodule Hub.Repo.Migrations.CreateMessageThreads do
  use Ecto.Migration

  def change do
    create table(:message_threads, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :thread_id, :string, null: false
      add :subject, :string, null: false
      add :scope, :string, default: "dm"
      add :status, :string, default: "open"
      add :participant_ids, {:array, :string}, default: []
      add :task_id, :string
      add :metadata, :map, default: %{}
      add :message_count, :integer, default: 0
      add :last_message_at, :utc_datetime
      add :closed_at, :utc_datetime
      add :closed_by, :string
      add :close_reason, :string
      add :created_by, :string, null: false
      add :fleet_id, references(:fleets, type: :binary_id, on_delete: :delete_all), null: false
      add :squad_id, references(:groups, type: :binary_id, on_delete: :nilify_all)
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      timestamps()
    end

    create unique_index(:message_threads, [:thread_id])
    create index(:message_threads, [:fleet_id, :status])
    create index(:message_threads, [:task_id])
    create index(:message_threads, [:tenant_id])
    create index(:message_threads, :participant_ids, using: :gin)
  end
end
