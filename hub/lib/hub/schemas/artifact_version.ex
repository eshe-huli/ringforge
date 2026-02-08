defmodule Hub.Schemas.ArtifactVersion do
  @moduledoc """
  Tracks every version of an artifact for full history and diff support.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "artifact_versions" do
    field :artifact_id, :string
    field :version, :integer
    field :s3_key, :string
    field :size, :integer
    field :checksum, :string
    field :created_by, :string
    field :change_description, :string
    field :metadata, :map, default: %{}

    belongs_to :fleet, Hub.Auth.Fleet
    belongs_to :tenant, Hub.Auth.Tenant

    timestamps()
  end

  @required_fields ~w(artifact_id version s3_key size checksum created_by fleet_id tenant_id)a
  @optional_fields ~w(change_description metadata)a

  def changeset(version, attrs) do
    version
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_number(:version, greater_than: 0)
    |> validate_number(:size, greater_than: 0)
    |> unique_constraint([:artifact_id, :version], name: :artifact_versions_artifact_id_version_index)
    |> foreign_key_constraint(:fleet_id)
    |> foreign_key_constraint(:tenant_id)
  end
end
