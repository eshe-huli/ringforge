defmodule Hub.Repo.Migrations.CreateGroups do
  use Ecto.Migration

  def change do
    # Groups: squads (persistent), pods (ephemeral), channels (topic-based)
    create table(:groups, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :group_id, :string, null: false
      add :name, :string, null: false
      add :type, :string, null: false, default: "squad"
      add :fleet_id, references(:fleets, type: :binary_id, on_delete: :delete_all), null: false
      add :created_by, :string  # agent_id of creator
      add :capabilities, {:array, :string}, default: []
      add :settings, :jsonb, default: "{}"
      add :status, :string, default: "active"  # active, dissolved
      add :dissolved_at, :utc_datetime
      add :result, :text  # final result when pod dissolves

      timestamps()
    end

    create unique_index(:groups, [:group_id])
    create unique_index(:groups, [:name, :fleet_id])
    create index(:groups, [:fleet_id])
    create index(:groups, [:type])
    create index(:groups, [:status])

    # Group membership
    create table(:group_members, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :group_id, references(:groups, type: :binary_id, on_delete: :delete_all), null: false
      add :agent_id, :string, null: false
      add :role, :string, default: "member"  # member, admin, owner
      add :joined_at, :utc_datetime, null: false

      timestamps()
    end

    create unique_index(:group_members, [:group_id, :agent_id])
    create index(:group_members, [:agent_id])
  end
end
