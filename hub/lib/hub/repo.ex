defmodule Hub.Repo do
  @moduledoc """
  Ecto repository for Ringforge hub.

  Connects to the Postgres database for tenant, fleet,
  API key, and agent metadata.
  """
  use Ecto.Repo,
    otp_app: :hub,
    adapter: Ecto.Adapters.Postgres
end
