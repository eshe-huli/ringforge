defmodule Hub.Repo.Migrations.AddMultiFleetAndSquadAssignment do
  use Ecto.Migration

  def change do
    # Add description to fleets
    alter table(:fleets) do
      add :description, :text
    end

    # Add squad_id to agents for squad-level assignment
    alter table(:agents) do
      add :squad_id, references(:groups, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:agents, [:squad_id])
  end
end
