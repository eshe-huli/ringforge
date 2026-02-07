defmodule Hub.Billing.Subscription do
  @moduledoc """
  Ecto schema for Stripe subscriptions.

  Each tenant has at most one active subscription. Free tenants
  simply have no subscription record (or a canceled one).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "subscriptions" do
    field :stripe_customer_id, :string
    field :stripe_subscription_id, :string
    field :stripe_price_id, :string
    field :plan, :string, default: "free"
    field :status, :string, default: "active"
    field :trial_ends_at, :utc_datetime
    field :current_period_start, :utc_datetime
    field :current_period_end, :utc_datetime
    field :canceled_at, :utc_datetime

    belongs_to :tenant, Hub.Auth.Tenant

    timestamps()
  end

  @required_fields ~w(tenant_id stripe_customer_id stripe_subscription_id plan status)a
  @optional_fields ~w(stripe_price_id trial_ends_at current_period_start current_period_end canceled_at)a

  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:plan, ~w(free pro scale enterprise))
    |> validate_inclusion(:status, ~w(active canceled past_due trialing incomplete))
    |> unique_constraint(:tenant_id)
    |> unique_constraint(:stripe_subscription_id)
  end
end
