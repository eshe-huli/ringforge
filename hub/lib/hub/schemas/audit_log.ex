defmodule Hub.Schemas.AuditLog do
  @moduledoc """
  Schema for structured audit logs.

  Records all security-relevant operations with actor, target, and
  metadata. Used for compliance, debugging, and security analysis.
  Tenant-scoped for multi-tenant isolation.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "audit_logs" do
    field :action, :string
    field :actor_type, :string
    field :actor_id, :string
    field :target_type, :string
    field :target_id, :string
    field :ip_address, :string
    field :metadata, :map, default: %{}

    belongs_to :tenant, Hub.Auth.Tenant

    field :inserted_at, :utc_datetime_usec, read_after_writes: true
  end

  @required_fields ~w(action actor_type actor_id)a
  @optional_fields ~w(target_type target_id ip_address metadata tenant_id)a

  def changeset(log, attrs) do
    log
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:action, max: 255)
    |> validate_length(:actor_type, max: 50)
    |> validate_length(:actor_id, max: 255)
    |> validate_length(:target_type, max: 50)
    |> validate_length(:target_id, max: 255)
    |> validate_length(:ip_address, max: 45)
    |> foreign_key_constraint(:tenant_id)
  end
end
