defmodule Hub.Repo.Migrations.CreateFiles do
  use Ecto.Migration

  def change do
    create table(:files, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :fleet_id, references(:fleets, type: :binary_id, on_delete: :delete_all), null: false
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :agent_id, :string, null: false
      add :filename, :string, null: false
      add :content_type, :string, null: false
      add :size, :bigint, null: false
      add :s3_key, :string, null: false
      add :tags, {:array, :string}, default: []
      add :description, :text

      timestamps()
    end

    create index(:files, [:fleet_id])
    create index(:files, [:tenant_id])
    create index(:files, [:agent_id])
    create index(:files, [:s3_key], unique: true)
    create index(:files, [:tags], using: :gin)
  end
end
