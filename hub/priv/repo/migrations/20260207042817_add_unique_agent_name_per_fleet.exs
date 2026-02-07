defmodule Hub.Repo.Migrations.AddUniqueAgentNamePerFleet do
  use Ecto.Migration

  def change do
    # Unique constraint: one agent name per fleet (NULL names are exempt)
    create unique_index(:agents, [:name, :fleet_id],
      where: "name IS NOT NULL",
      name: :agents_name_fleet_id_unique
    )
  end
end
