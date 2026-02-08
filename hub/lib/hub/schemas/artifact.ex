defmodule Hub.Schemas.Artifact do
  @moduledoc """
  Schema for agent-produced artifacts — versioned file deliverables linked to kanban tasks.

  Artifacts flow through review: pending_review → approved | rejected | superseded
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_statuses ~w(pending_review approved rejected superseded)

  def valid_statuses, do: @valid_statuses

  schema "artifacts" do
    field :artifact_id, :string
    field :task_id, :string
    field :filename, :string
    field :path, :string
    field :content_type, :string
    field :language, :string
    field :version, :integer, default: 1
    field :size, :integer
    field :checksum, :string
    field :s3_key, :string
    field :description, :string
    field :status, :string, default: "pending_review"
    field :reviewed_by, :string
    field :review_notes, :string
    field :reviewed_at, :utc_datetime
    field :tags, {:array, :string}, default: []
    field :metadata, :map, default: %{}
    field :created_by, :string

    belongs_to :fleet, Hub.Auth.Fleet
    belongs_to :squad, Hub.Groups.Group
    belongs_to :tenant, Hub.Auth.Tenant

    timestamps()
  end

  @required_fields ~w(artifact_id filename content_type size checksum s3_key created_by fleet_id tenant_id)a
  @optional_fields ~w(task_id path language version description status reviewed_by review_notes reviewed_at tags metadata squad_id)a

  def changeset(artifact, attrs) do
    artifact
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_length(:filename, max: 500)
    |> validate_length(:description, max: 4000)
    |> validate_length(:tags, max: 50)
    |> validate_number(:size, greater_than: 0)
    |> validate_number(:version, greater_than: 0)
    |> validate_format(:artifact_id, ~r/^art_[A-Za-z0-9]+$/)
    |> unique_constraint(:artifact_id)
    |> foreign_key_constraint(:fleet_id)
    |> foreign_key_constraint(:tenant_id)
    |> foreign_key_constraint(:squad_id)
  end

  def review_changeset(artifact, attrs) do
    artifact
    |> cast(attrs, [:status, :reviewed_by, :review_notes, :reviewed_at])
    |> validate_required([:status, :reviewed_by, :reviewed_at])
    |> validate_inclusion(:status, ~w(approved rejected))
  end
end
