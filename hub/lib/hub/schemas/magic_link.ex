defmodule Hub.Auth.MagicLink do
  @moduledoc """
  Schema for magic link email login tokens.

  Stores a hashed token with a 15-minute TTL. The raw token is sent
  to the user via email (or logged to console in dev). On verification,
  the token is deleted to prevent reuse.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "magic_links" do
    field :token_hash, :string
    field :email, :string
    field :expires_at, :utc_datetime

    timestamps(updated_at: false)
  end

  def changeset(magic_link, attrs) do
    magic_link
    |> cast(attrs, [:token_hash, :email, :expires_at])
    |> validate_required([:token_hash, :email, :expires_at])
    |> unique_constraint(:token_hash)
  end
end
