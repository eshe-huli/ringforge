defmodule Hub.Repo.Migrations.AddTenantAuth do
  use Ecto.Migration

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS citext"

    alter table(:tenants) do
      add :email, :citext
      add :password_hash, :string
    end

    create unique_index(:tenants, [:email], where: "email IS NOT NULL")
  end

  def down do
    drop_if_exists unique_index(:tenants, [:email])

    alter table(:tenants) do
      remove :email
      remove :password_hash
    end
  end
end
