defmodule Hub.Schemas.File do
  @moduledoc """
  Schema for files shared through the RingForge mesh.

  Files are stored in S3 (Garage) and tracked in Postgres with metadata.
  All operations are tenant-scoped for strict isolation.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "files" do
    field :filename, :string
    field :content_type, :string
    field :size, :integer
    field :s3_key, :string
    field :tags, {:array, :string}, default: []
    field :description, :string
    field :agent_id, :string

    belongs_to :fleet, Hub.Auth.Fleet
    belongs_to :tenant, Hub.Auth.Tenant

    timestamps()
  end

  @required_fields ~w(filename content_type size s3_key agent_id fleet_id tenant_id)a
  @optional_fields ~w(tags description)a

  def changeset(file, attrs) do
    file
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_number(:size, greater_than: 0, less_than_or_equal_to: 500_000_000)
    |> validate_length(:filename, max: 255)
    |> validate_length(:tags, max: 20)
    |> foreign_key_constraint(:fleet_id)
    |> foreign_key_constraint(:tenant_id)
  end
end
