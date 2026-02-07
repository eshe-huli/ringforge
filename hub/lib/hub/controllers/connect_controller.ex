defmodule Hub.ConnectController do
  @moduledoc """
  Pre-flight endpoint for agents to validate their connection config
  before attempting WebSocket. Returns clear, actionable errors.

  GET /api/connect/check?api_key=rf_live_...
  """
  use Phoenix.Controller, formats: [:json]
  require Logger

  def check(conn, params) do
    api_key = params["api_key"] || params["key"]

    cond do
      is_nil(api_key) || api_key == "" ->
        json(conn, %{
          ok: false,
          error: "missing_api_key",
          message: "No API key provided.",
          fix: "Add ?api_key=rf_live_... to your WebSocket URL, or pass --key rf_live_... to the connect script."
        })

      not String.starts_with?(api_key, "rf_") ->
        json(conn, %{
          ok: false,
          error: "invalid_key_format",
          message: "API key must start with 'rf_live_' (for agents) or 'rf_admin_' (for dashboard).",
          fix: "Generate a key via the admin API or dashboard. Keys look like: rf_live_abc123..."
        })

      String.starts_with?(api_key, "rf_admin_") ->
        json(conn, %{
          ok: false,
          error: "wrong_key_type",
          message: "You're using an admin key (rf_admin_*). Agents need a live key (rf_live_*).",
          fix: "Use a 'rf_live_...' key for agent connections. Admin keys are for the dashboard only."
        })

      true ->
        case Hub.Auth.validate_api_key(api_key) do
          {:ok, key_record} ->
            fleet = load_fleet(key_record)
            tenant = Hub.Repo.get(Hub.Auth.Tenant, key_record.tenant_id)

            json(conn, %{
              ok: true,
              message: "Key valid. Ready to connect.",
              tenant: %{
                id: key_record.tenant_id,
                name: (tenant && tenant.name) || "unknown",
                plan: (tenant && tenant.plan) || "free"
              },
              fleet: if(fleet, do: %{id: fleet.id, name: fleet.name}, else: nil),
              websocket: %{
                url: "wss://#{conn.host}/ws/websocket?vsn=2.0.0&api_key=YOUR_KEY&agent={...}",
                vsn: "2.0.0",
                channel: if(fleet, do: "fleet:#{fleet.id}", else: nil)
              },
              hint: "Connect via WebSocket with vsn=2.0.0. Join channel 'fleet:<fleet_id>' after connecting."
            })

          {:error, reason} ->
            json(conn, %{
              ok: false,
              error: "auth_failed",
              message: "API key validation failed: #{inspect(reason)}",
              fix: "Check you copied the full key. Generate a new one from the dashboard Settings page."
            })
        end
    end
  end

  defp load_fleet(%{fleet_id: nil}), do: nil
  defp load_fleet(%{fleet_id: fleet_id}) do
    Hub.Repo.get(Hub.Auth.Fleet, fleet_id)
  end
  defp load_fleet(_), do: nil
end
