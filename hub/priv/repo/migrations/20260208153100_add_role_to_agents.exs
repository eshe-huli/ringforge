defmodule Hub.Repo.Migrations.AddRoleToAgents do
  use Ecto.Migration

  def change do
    alter table(:agents) do
      add :role_template_id, references(:role_templates, type: :binary_id, on_delete: :nilify_all)
      add :context_tier, :string
      add :tier_calibrated_at, :utc_datetime
    end

    create index(:agents, [:role_template_id])
  end
end
