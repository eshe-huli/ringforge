defmodule Hub.Repo.Migrations.CreateFleets do
  use Ecto.Migration

  def change do
    create table(:fleets, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :string, default: "default"

      timestamps()
    end

    create unique_index(:fleets, [:tenant_id, :name])
  end
end
