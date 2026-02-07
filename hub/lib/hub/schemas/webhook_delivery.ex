defmodule Hub.Schemas.WebhookDelivery do
  @moduledoc """
  Schema for webhook delivery attempts.

  Tracks each attempt to deliver an event to a webhook URL,
  including HTTP response status, body (truncated to 1KB),
  and retry scheduling.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "webhook_deliveries" do
    field :event_type, :string
    field :payload, :map, default: %{}
    field :response_status, :integer
    field :response_body, :string
    field :attempt, :integer, default: 1
    field :delivered_at, :utc_datetime
    field :next_retry_at, :utc_datetime
    field :status, :string, default: "pending"

    belongs_to :webhook, Hub.Schemas.Webhook
  end

  @required_fields ~w(webhook_id event_type payload attempt delivered_at status)a
  @optional_fields ~w(response_status response_body next_retry_at)a

  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, ~w(success failed pending))
    |> validate_number(:attempt, greater_than: 0, less_than_or_equal_to: 3)
    |> truncate_response_body()
    |> foreign_key_constraint(:webhook_id)
  end

  defp truncate_response_body(changeset) do
    case get_change(changeset, :response_body) do
      nil -> changeset
      body when byte_size(body) > 1024 -> put_change(changeset, :response_body, binary_part(body, 0, 1024))
      _ -> changeset
    end
  end
end
