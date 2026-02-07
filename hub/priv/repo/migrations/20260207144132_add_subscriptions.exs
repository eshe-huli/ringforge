defmodule Hub.Repo.Migrations.AddSubscriptions do
  use Ecto.Migration

  def change do
    # Add stripe_customer_id to tenants
    alter table(:tenants) do
      add :stripe_customer_id, :string
    end

    create index(:tenants, [:stripe_customer_id], unique: true)

    # Create subscriptions table
    create table(:subscriptions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :stripe_customer_id, :string, null: false
      add :stripe_subscription_id, :string, null: false
      add :stripe_price_id, :string
      add :plan, :string, null: false, default: "free"
      add :status, :string, null: false, default: "active"
      add :trial_ends_at, :utc_datetime
      add :current_period_start, :utc_datetime
      add :current_period_end, :utc_datetime
      add :canceled_at, :utc_datetime

      timestamps()
    end

    create unique_index(:subscriptions, [:tenant_id])
    create unique_index(:subscriptions, [:stripe_subscription_id])
    create index(:subscriptions, [:stripe_customer_id])
    create index(:subscriptions, [:status])
  end
end
