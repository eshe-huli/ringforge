defmodule Hub.Repo.Migrations.CreateArtifacts do
  use Ecto.Migration

  def change do
    create table(:artifacts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :artifact_id, :string, null: false
      add :task_id, :string
      add :filename, :string, null: false
      add :path, :string
      add :content_type, :string, null: false
      add :language, :string
      add :version, :integer, default: 1, null: false
      add :size, :integer, null: false
      add :checksum, :string, null: false
      add :s3_key, :string, null: false
      add :description, :text
      add :status, :string, default: "pending_review", null: false
      add :reviewed_by, :string
      add :review_notes, :text
      add :reviewed_at, :utc_datetime
      add :tags, {:array, :string}, default: []
      add :metadata, :map, default: %{}
      add :created_by, :string, null: false

      add :fleet_id, references(:fleets, type: :binary_id, on_delete: :delete_all), null: false
      add :squad_id, references(:groups, type: :binary_id, on_delete: :nilify_all)
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      timestamps()
    end

    create unique_index(:artifacts, [:artifact_id])
    create index(:artifacts, [:task_id])
    create index(:artifacts, [:fleet_id])
    create index(:artifacts, [:status])
    create index(:artifacts, [:created_by])
    create index(:artifacts, [:tags], using: "GIN")

    create table(:artifact_versions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :artifact_id, :string, null: false
      add :version, :integer, null: false
      add :s3_key, :string, null: false
      add :size, :integer, null: false
      add :checksum, :string, null: false
      add :created_by, :string, null: false
      add :change_description, :text
      add :metadata, :map, default: %{}

      add :fleet_id, references(:fleets, type: :binary_id, on_delete: :delete_all), null: false
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false

      timestamps()
    end

    create unique_index(:artifact_versions, [:artifact_id, :version])
    create index(:artifact_versions, [:fleet_id])
  end
end
