defmodule Hub.Providers.Hetzner do
  @moduledoc """
  Hetzner Cloud API v1 provider implementation.

  API docs: https://docs.hetzner.cloud/
  Auth: Bearer token via `Authorization: Bearer <api_token>`
  """
  @behaviour Hub.Providers.Provider

  @base_url "https://api.hetzner.cloud/v1"

  @impl true
  def list_regions(credentials) do
    case api_get(credentials, "/locations") do
      {:ok, %{"locations" => locations}} ->
        regions = Enum.map(locations, fn loc ->
          %{
            id: loc["name"],
            name: "#{loc["description"]} (#{loc["city"]})",
            available: true
          }
        end)
        {:ok, regions}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def list_sizes(credentials) do
    case api_get(credentials, "/server_types") do
      {:ok, %{"server_types" => types}} ->
        sizes = Enum.map(types, fn t ->
          monthly = Enum.find(t["prices"] || [], fn p -> p["location"] == "fsn1" end)
          monthly_gross = get_in(monthly, ["price_monthly", "gross"]) || "0"
          cost_cents = (String.to_float(monthly_gross) * 100) |> round()

          %{
            id: t["name"],
            name: t["description"],
            vcpus: t["cores"],
            memory_mb: t["memory"] |> Kernel.*(1024) |> round(),
            disk_gb: t["disk"],
            monthly_cost_cents: cost_cents
          }
        end)
        {:ok, sizes}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def create_server(credentials, opts) do
    user_data = Hub.Providers.CloudInit.generate(%{
      api_key: opts[:api_key],
      agent_name: opts[:name],
      template: opts[:template] || "openclaw",
      hub_url: opts[:hub_url]
    })

    body = %{
      name: opts[:name],
      server_type: opts[:size],
      location: opts[:region],
      image: "ubuntu-24.04",
      user_data: user_data,
      start_after_create: true,
      labels: %{
        "managed-by" => "ringforge",
        "fleet" => opts[:fleet_id] || "default"
      }
    }

    case api_post(credentials, "/servers", body) do
      {:ok, %{"server" => server}} ->
        ip = get_in(server, ["public_net", "ipv4", "ip"])
        {:ok, %{
          external_id: to_string(server["id"]),
          ip_address: ip,
          status: normalize_status(server["status"]),
          name: server["name"]
        }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def destroy_server(credentials, external_id) do
    case api_delete(credentials, "/servers/#{external_id}") do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def get_server(credentials, external_id) do
    case api_get(credentials, "/servers/#{external_id}") do
      {:ok, %{"server" => server}} ->
        ip = get_in(server, ["public_net", "ipv4", "ip"])
        {:ok, %{
          external_id: to_string(server["id"]),
          ip_address: ip,
          status: normalize_status(server["status"]),
          name: server["name"]
        }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Private helpers ──────────────────────────────────────

  defp api_get(credentials, path) do
    url = @base_url <> path
    headers = auth_headers(credentials)

    case :hackney.request(:get, url, headers, "", [recv_timeout: 15_000]) do
      {:ok, status, _headers, ref} when status in 200..299 ->
        {:ok, body} = :hackney.body(ref)
        {:ok, Jason.decode!(body)}

      {:ok, status, _headers, ref} ->
        {:ok, body} = :hackney.body(ref)
        {:error, %{status: status, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp api_post(credentials, path, body) do
    url = @base_url <> path
    headers = [{"Content-Type", "application/json"} | auth_headers(credentials)]
    payload = Jason.encode!(body)

    case :hackney.request(:post, url, headers, payload, [recv_timeout: 30_000]) do
      {:ok, status, _headers, ref} when status in 200..299 ->
        {:ok, resp_body} = :hackney.body(ref)
        {:ok, Jason.decode!(resp_body)}

      {:ok, status, _headers, ref} ->
        {:ok, resp_body} = :hackney.body(ref)
        {:error, %{status: status, body: resp_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp api_delete(credentials, path) do
    url = @base_url <> path
    headers = auth_headers(credentials)

    case :hackney.request(:delete, url, headers, "", [recv_timeout: 15_000]) do
      {:ok, status, _headers, ref} when status in 200..299 ->
        {:ok, body} = :hackney.body(ref)
        {:ok, if(body == "", do: %{}, else: Jason.decode!(body))}

      {:ok, status, _headers, ref} ->
        {:ok, body} = :hackney.body(ref)
        {:error, %{status: status, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp auth_headers(%{"api_token" => token}), do: [{"Authorization", "Bearer #{token}"}]
  defp auth_headers(%{api_token: token}), do: [{"Authorization", "Bearer #{token}"}]
  defp auth_headers(_), do: []

  defp normalize_status("running"), do: "running"
  defp normalize_status("initializing"), do: "provisioning"
  defp normalize_status("starting"), do: "provisioning"
  defp normalize_status("stopping"), do: "stopped"
  defp normalize_status("off"), do: "stopped"
  defp normalize_status("deleting"), do: "destroyed"
  defp normalize_status(_), do: "error"
end
