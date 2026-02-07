defmodule Hub.Providers.DigitalOcean do
  @moduledoc """
  DigitalOcean API v2 provider implementation.

  API docs: https://docs.digitalocean.com/reference/api/
  Auth: Bearer token via `Authorization: Bearer <api_token>`
  """
  @behaviour Hub.Providers.Provider

  @base_url "https://api.digitalocean.com/v2"

  @impl true
  def list_regions(credentials) do
    case api_get(credentials, "/regions") do
      {:ok, %{"regions" => regions}} ->
        result = Enum.map(regions, fn r ->
          %{
            id: r["slug"],
            name: r["name"],
            available: r["available"]
          }
        end)
        {:ok, result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def list_sizes(credentials) do
    case api_get(credentials, "/sizes") do
      {:ok, %{"sizes" => sizes}} ->
        result = Enum.map(sizes, fn s ->
          %{
            id: s["slug"],
            name: s["slug"],
            vcpus: s["vcpus"],
            memory_mb: s["memory"],
            disk_gb: s["disk"],
            monthly_cost_cents: round((s["price_monthly"] || 0) * 100)
          }
        end)
        {:ok, result}

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
      region: opts[:region],
      size: opts[:size],
      image: "ubuntu-24-04-x64",
      user_data: user_data,
      tags: ["ringforge", "fleet:#{opts[:fleet_id] || "default"}"]
    }

    case api_post(credentials, "/droplets", body) do
      {:ok, %{"droplet" => droplet}} ->
        ip = extract_ipv4(droplet)
        {:ok, %{
          external_id: to_string(droplet["id"]),
          ip_address: ip,
          status: normalize_status(droplet["status"]),
          name: droplet["name"]
        }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def destroy_server(credentials, external_id) do
    case api_delete(credentials, "/droplets/#{external_id}") do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def get_server(credentials, external_id) do
    case api_get(credentials, "/droplets/#{external_id}") do
      {:ok, %{"droplet" => droplet}} ->
        ip = extract_ipv4(droplet)
        {:ok, %{
          external_id: to_string(droplet["id"]),
          ip_address: ip,
          status: normalize_status(droplet["status"]),
          name: droplet["name"]
        }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Private helpers ──────────────────────────────────────

  defp extract_ipv4(droplet) do
    networks = get_in(droplet, ["networks", "v4"]) || []
    case Enum.find(networks, fn n -> n["type"] == "public" end) do
      %{"ip_address" => ip} -> ip
      _ -> nil
    end
  end

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
      {:ok, status, _headers, _ref} when status in [204, 200] ->
        {:ok, %{}}

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

  defp normalize_status("active"), do: "running"
  defp normalize_status("new"), do: "provisioning"
  defp normalize_status("off"), do: "stopped"
  defp normalize_status("archive"), do: "destroyed"
  defp normalize_status(_), do: "error"
end
