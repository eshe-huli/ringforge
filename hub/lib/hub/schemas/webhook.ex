defmodule Hub.Schemas.Webhook do
  @moduledoc """
  Schema for outbound webhook endpoints.

  Tenants configure webhook URLs to receive event notifications.
  Each webhook subscribes to specific event types and optionally scopes
  to a single fleet (null fleet_id = all fleets).

  Payloads are signed with HMAC-SHA256 using the stored secret.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_events ~w(
    agent.connected agent.disconnected
    message.received
    activity.broadcast
    memory.changed
    task.submitted task.completed task.failed
    file.shared file.deleted
  )

  schema "webhooks" do
    field :url, :string
    field :secret, :string
    field :events, {:array, :string}, default: []
    field :active, :boolean, default: true
    field :description, :string

    belongs_to :tenant, Hub.Auth.Tenant
    belongs_to :fleet, Hub.Auth.Fleet

    has_many :deliveries, Hub.Schemas.WebhookDelivery

    timestamps()
  end

  @required_fields ~w(url events)a
  @optional_fields ~w(fleet_id active description)a

  def changeset(webhook, attrs) do
    webhook
    |> cast(attrs, @required_fields ++ @optional_fields ++ [:secret, :tenant_id])
    |> validate_required(@required_fields)
    |> validate_https_url()
    |> validate_events()
    |> validate_length(:url, max: 2048)
    |> validate_length(:description, max: 500)
    |> foreign_key_constraint(:tenant_id)
    |> foreign_key_constraint(:fleet_id)
  end

  def valid_events, do: @valid_events

  defp validate_https_url(changeset) do
    validate_change(changeset, :url, fn :url, url ->
      uri = URI.parse(url)

      cond do
        uri.scheme != "https" ->
          [url: "must use HTTPS"]

        is_nil(uri.host) or uri.host == "" ->
          [url: "must have a valid host"]

        true ->
          []
      end
    end)
  end

  defp validate_events(changeset) do
    validate_change(changeset, :events, fn :events, events ->
      invalid = Enum.reject(events, &(&1 in @valid_events))

      if invalid == [] do
        []
      else
        [events: "contains invalid event types: #{Enum.join(invalid, ", ")}"]
      end
    end)
  end
end
