defmodule Hub.Repo.Migrations.CreateKanbanTasks do
  use Ecto.Migration

  def change do
    create table(:kanban_tasks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :task_id, :string, null: false
      add :title, :string, null: false
      add :description, :text
      add :lane, :string, null: false, default: "backlog"
      add :priority, :string, null: false, default: "medium"
      add :effort, :string, null: false, default: "medium"
      add :requires_capabilities, {:array, :string}, default: []
      add :depends_on, {:array, :string}, default: []
      add :blocked_by, {:array, :string}, default: []
      add :acceptance_criteria, {:array, :string}, default: []
      add :context_refs, {:array, :string}, default: []
      add :tags, {:array, :string}, default: []
      add :progress, :text
      add :progress_pct, :integer, default: 0
      add :result, :text
      add :deadline, :utc_datetime
      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime
      add :estimated_minutes, :integer
      add :actual_minutes, :integer
      add :metadata, :map, default: %{}

      add :scope, :string, null: false, default: "fleet"

      add :fleet_id, references(:fleets, type: :binary_id, on_delete: :delete_all), null: false
      add :squad_id, references(:groups, type: :binary_id, on_delete: :nilify_all)
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      add :created_by, :string
      add :assigned_to, :string
      add :reviewed_by, :string

      add :position, :integer, default: 0

      timestamps()
    end

    create unique_index(:kanban_tasks, [:task_id])
    create index(:kanban_tasks, [:fleet_id, :lane])
    create index(:kanban_tasks, [:squad_id, :lane])
    create index(:kanban_tasks, [:assigned_to])
    create index(:kanban_tasks, [:tenant_id])
    create index(:kanban_tasks, [:lane, :position])
    create index(:kanban_tasks, [:fleet_id, :assigned_to])
    create index(:kanban_tasks, [:tags], using: :gin)

    # ── History table for lane transitions ──

    create table(:kanban_task_history, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :kanban_task_id, references(:kanban_tasks, type: :binary_id, on_delete: :delete_all), null: false
      add :from_lane, :string
      add :to_lane, :string, null: false
      add :changed_by, :string
      add :reason, :text

      timestamps()
    end

    create index(:kanban_task_history, [:kanban_task_id])
    create index(:kanban_task_history, [:kanban_task_id, :inserted_at])
  end
end
