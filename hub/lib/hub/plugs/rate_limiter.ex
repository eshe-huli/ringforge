defmodule Hub.Plugs.RateLimiter do
  @moduledoc """
  Advanced rate limiter plug with per-IP and per-API-key limits.

  Uses ETS counters with a sliding window for efficient rate limiting.

  ## Limits

  - Auth endpoints (login, register, magic-link): 5 requests/minute per IP
  - API endpoints: 60 requests/minute per API key

  Returns `429 Too Many Requests` with `Retry-After` header when exceeded.

  ## Usage

      # In router pipeline:
      plug Hub.Plugs.RateLimiter, scope: :auth   # 5/min per IP
      plug Hub.Plugs.RateLimiter, scope: :api     # 60/min per key
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  @behaviour Plug

  @table :hub_rate_limiter
  @window_ms 60_000

  @limits %{
    auth: 5,
    api: 60
  }

  @doc "Create the ETS table. Called from Hub.Application or Hub.Quota."
  def init_table do
    if :ets.info(@table) == :undefined do
      :ets.new(@table, [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])
    end

    :ok
  end

  @impl Plug
  def init(opts) do
    scope = Keyword.get(opts, :scope, :api)
    %{scope: scope, max: Map.get(@limits, scope, 60)}
  end

  @impl Plug
  def call(conn, %{scope: scope, max: max}) do
    key = rate_key(conn, scope)
    now = System.monotonic_time(:millisecond)
    window_start = now - @window_ms

    # Ensure table exists
    if :ets.info(@table) == :undefined do
      init_table()
    end

    # Get current timestamps, prune old ones
    timestamps =
      case :ets.lookup(@table, key) do
        [{^key, ts_list}] ->
          Enum.filter(ts_list, &(&1 > window_start))

        [] ->
          []
      end

    if length(timestamps) >= max do
      oldest = Enum.min(timestamps)
      retry_after = ceil((@window_ms - (now - oldest)) / 1000)

      conn
      |> put_resp_header("retry-after", Integer.to_string(max(retry_after, 1)))
      |> put_status(429)
      |> json(%{
        error: "rate_limited",
        message: "Too many requests. Limit: #{max}/minute.",
        retry_after: max(retry_after, 1)
      })
      |> halt()
    else
      :ets.insert(@table, {key, [now | timestamps]})
      conn
    end
  end

  defp rate_key(conn, :auth) do
    ip = conn.remote_ip |> :inet.ntoa() |> to_string()
    {:rate_auth, ip}
  end

  defp rate_key(conn, :api) do
    case conn.assigns[:api_key] do
      %{id: id} -> {:rate_api, id}
      _ ->
        ip = conn.remote_ip |> :inet.ntoa() |> to_string()
        {:rate_api, ip}
    end
  end
end
