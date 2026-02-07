defmodule Hub.Repo.Migrations.AddAgentProfilesAndSessions do
  use Ecto.Migration

  def change do
    # ── Agent profile fields ──────────────────────────────────
    alter table(:agents) do
      add :display_name, :string
      add :avatar_url, :string
      add :description, :text
      add :tags, :jsonb, default: "[]"
      add :metadata, :jsonb, default: "{}"
      add :total_connections, :integer, default: 0, null: false
      add :total_messages, :integer, default: 0, null: false
    end

    # ── Agent sessions table ──────────────────────────────────
    create table(:agent_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false
      add :fleet_id, references(:fleets, type: :binary_id, on_delete: :nilify_all)
      add :connected_at, :utc_datetime, null: false
      add :disconnected_at, :utc_datetime
      add :disconnect_reason, :string
      add :ip_address, :string

      timestamps()
    end

    create index(:agent_sessions, [:agent_id])
    create index(:agent_sessions, [:fleet_id])
    create index(:agent_sessions, [:connected_at])
  end
end
