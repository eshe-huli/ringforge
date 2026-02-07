defmodule Hub.Plugs.RawBodyReader do
  @moduledoc """
  Plug parser that caches the raw request body for webhook signature verification.

  Used in the `:stripe_webhook` pipeline so that `conn.assigns[:raw_body]`
  contains the original body bytes for Stripe signature verification.
  """

  @behaviour Plug

  def init(opts), do: opts

  def call(conn, _opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    conn = Plug.Conn.assign(conn, :raw_body, body)

    # Re-parse as JSON so params are available
    case Jason.decode(body) do
      {:ok, params} -> %{conn | body_params: params, params: Map.merge(conn.params, params)}
      _ -> conn
    end
  end
end
