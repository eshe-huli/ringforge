defmodule Hub.Repo.Migrations.AddSocialAuthAndInvites do
  use Ecto.Migration

  def change do
    # --- Social auth fields on tenants ---
    alter table(:tenants) do
      add :github_id, :string
      add :github_username, :string
      add :google_id, :string
      add :auth_provider, :string, default: "email"
    end

    create unique_index(:tenants, [:github_id], where: "github_id IS NOT NULL")
    create unique_index(:tenants, [:google_id], where: "google_id IS NOT NULL")

    # --- Magic links ---
    create table(:magic_links, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :token_hash, :string, null: false
      add :email, :citext, null: false
      add :expires_at, :utc_datetime, null: false

      timestamps(updated_at: false)
    end

    create unique_index(:magic_links, [:token_hash])
    create index(:magic_links, [:email])

    # --- Invite codes ---
    create table(:invite_codes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :code, :string, null: false
      add :max_uses, :integer, default: 1
      add :uses, :integer, default: 0
      add :created_by, references(:tenants, type: :binary_id, on_delete: :delete_all), null: false
      add :expires_at, :utc_datetime

      timestamps(updated_at: false)
    end

    create unique_index(:invite_codes, [:code])
    create index(:invite_codes, [:created_by])
  end
end
