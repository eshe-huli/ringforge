defmodule Hub.Repo.Migrations.CreateProvisioningTables do
  use Ecto.Migration

  def change do
    # ── Provider Credentials ────────────────────────────────

    create table(:provider_credentials, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :provider, :string, null: false
      add :name, :string, null: false
      add :credentials, :map, null: false
      add :active, :boolean, default: true, null: false

      timestamps()
    end

    create index(:provider_credentials, [:tenant_id])
    create index(:provider_credentials, [:tenant_id, :provider])

    # ── Provisioned Agents ──────────────────────────────────

    create table(:provisioned_agents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :fleet_id, references(:fleets, type: :binary_id, on_delete: :nilify_all)
      add :provider_credential_id, references(:provider_credentials, type: :binary_id, on_delete: :nilify_all)
      add :provider, :string, null: false
      add :external_id, :string
      add :name, :string, null: false
      add :ip_address, :string
      add :status, :string, null: false, default: "provisioning"
      add :region, :string, null: false
      add :size, :string, null: false
      add :template, :string, null: false, default: "openclaw"
      add :agent_api_key, :string, null: false
      add :monthly_cost_cents, :integer, default: 0
      add :error_message, :text
      add :provisioned_at, :utc_datetime

      timestamps()
    end

    create index(:provisioned_agents, [:tenant_id])
    create index(:provisioned_agents, [:tenant_id, :status])
    create index(:provisioned_agents, [:provider_credential_id])
    create index(:provisioned_agents, [:external_id])
  end
end
