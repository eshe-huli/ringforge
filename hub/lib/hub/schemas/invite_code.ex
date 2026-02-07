defmodule Hub.Auth.InviteCode do
  @moduledoc """
  Schema for invite codes.

  Invite codes gate registration when the system is in invite-only mode.
  Each code has a max usage count and optional expiration date.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "invite_codes" do
    field :code, :string
    field :max_uses, :integer, default: 1
    field :uses, :integer, default: 0
    field :expires_at, :utc_datetime

    belongs_to :creator, Hub.Auth.Tenant, foreign_key: :created_by

    timestamps(updated_at: false)
  end

  def changeset(invite, attrs) do
    invite
    |> cast(attrs, [:code, :max_uses, :uses, :expires_at, :created_by])
    |> validate_required([:code, :created_by])
    |> unique_constraint(:code)
  end
end
