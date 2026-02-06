defmodule Hub.Plugs.RateLimit do
  @moduledoc """
  ETS-based sliding-window rate limiter for the REST API.

  Tracks requests per API key per minute. When the limit (60 req/min)
  is exceeded, returns 429 with a `Retry-After` header.

  The ETS table `:hub_rate_limits` is owned by `Hub.Quota` (a long-lived
  GenServer) and stores `{key, [timestamps]}` tuples.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  @behaviour Plug

  @table :hub_rate_limits
  @window_ms 60_000
  @max_requests 60

  @doc "Create the ETS table (called from Hub.Quota.init/1)."
  def init_table do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])
  end

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    key = rate_key(conn)
    now = System.monotonic_time(:millisecond)
    window_start = now - @window_ms

    # Get current timestamps, prune old ones
    timestamps =
      case :ets.lookup(@table, key) do
        [{^key, ts_list}] ->
          Enum.filter(ts_list, &(&1 > window_start))

        [] ->
          []
      end

    if length(timestamps) >= @max_requests do
      oldest = Enum.min(timestamps)
      retry_after = ceil((@window_ms - (now - oldest)) / 1000)

      conn
      |> put_resp_header("retry-after", Integer.to_string(max(retry_after, 1)))
      |> put_status(429)
      |> json(%{error: "rate_limited", message: "Too many requests", retry_after: max(retry_after, 1)})
      |> halt()
    else
      :ets.insert(@table, {key, [now | timestamps]})
      conn
    end
  end

  defp rate_key(conn) do
    case conn.assigns[:api_key] do
      %{id: id} -> {:rate, id}
      _ -> {:rate, conn.remote_ip |> :inet.ntoa() |> to_string()}
    end
  end
end
