defmodule Hub.Repo.Migrations.CreateRoleTemplates do
  use Ecto.Migration

  def change do
    create table(:role_templates, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :slug, :string, null: false
      add :name, :string, null: false
      add :system_prompt, :text, null: false
      add :capabilities, {:array, :string}, default: []
      add :constraints, {:array, :string}, default: []
      add :tools_allowed, {:array, :string}, default: []
      add :escalation_rules, :text
      add :context_injection_tier, :string, default: "auto"
      add :respond_format, :string
      add :respond_schema, :map
      add :is_predefined, :boolean, default: false
      add :metadata, :map, default: %{}
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all)
      timestamps()
    end

    create unique_index(:role_templates, [:slug, :tenant_id], name: :role_templates_slug_tenant_unique)
    create unique_index(:role_templates, [:slug], where: "tenant_id IS NULL", name: :role_templates_predefined_slug_unique)
    create index(:role_templates, [:tenant_id])
    create index(:role_templates, [:is_predefined])
  end
end
