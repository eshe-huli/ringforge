defmodule Hub.Providers.Contabo do
  @moduledoc """
  Contabo API provider implementation (stub).

  API docs: https://api.contabo.com/
  Auth: OAuth2 bearer token (requires client_id + client_secret + api_user + api_password)

  Note: Contabo's API requires OAuth2 token exchange first. This is a stub
  implementation with correct endpoints — full OAuth2 flow to be added.
  """
  @behaviour Hub.Providers.Provider

  @base_url "https://api.contabo.com/v1"
  @auth_url "https://auth.contabo.com/auth/realms/contabo/protocol/openid-connect/token"

  @impl true
  def list_regions(_credentials) do
    # Contabo has limited regions — return known ones
    {:ok, [
      %{id: "EU", name: "European Union (Nuremberg)", available: true},
      %{id: "US-central", name: "US Central (St. Louis)", available: true},
      %{id: "US-east", name: "US East (New York)", available: true},
      %{id: "US-west", name: "US West (Seattle)", available: true},
      %{id: "SIN", name: "Asia (Singapore)", available: true},
      %{id: "AUS", name: "Australia (Sydney)", available: true},
      %{id: "JPN", name: "Japan (Tokyo)", available: true},
      %{id: "UK", name: "United Kingdom (London)", available: true}
    ]}
  end

  @impl true
  def list_sizes(_credentials) do
    # Contabo's known VPS plans (approximate pricing)
    {:ok, [
      %{id: "V2", name: "VPS S (4 vCPU, 8GB RAM)", vcpus: 4, memory_mb: 8192, disk_gb: 200, monthly_cost_cents: 699},
      %{id: "V3", name: "VPS M (6 vCPU, 16GB RAM)", vcpus: 6, memory_mb: 16384, disk_gb: 400, monthly_cost_cents: 1349},
      %{id: "V4", name: "VPS L (8 vCPU, 30GB RAM)", vcpus: 8, memory_mb: 30720, disk_gb: 800, monthly_cost_cents: 2199},
      %{id: "V5", name: "VPS XL (10 vCPU, 60GB RAM)", vcpus: 10, memory_mb: 61440, disk_gb: 1600, monthly_cost_cents: 4049}
    ]}
  end

  @impl true
  def create_server(credentials, opts) do
    case get_access_token(credentials) do
      {:ok, token} ->
        user_data = Hub.Providers.CloudInit.generate(%{
          api_key: opts[:api_key],
          agent_name: opts[:name],
          template: opts[:template] || "openclaw",
          hub_url: opts[:hub_url]
        })

        body = %{
          imageId: "afecbb85-e2fc-46f0-9571-c60f7bbc0598",  # Ubuntu 24.04
          productId: opts[:size],
          region: opts[:region],
          displayName: opts[:name],
          userData: Base.encode64(user_data)
        }

        case api_post(token, "/compute/instances", body) do
          {:ok, %{"data" => [instance | _]}} ->
            ip = get_in(instance, ["ipConfig", "v4", "ip"])
            {:ok, %{
              external_id: to_string(instance["instanceId"]),
              ip_address: ip,
              status: normalize_status(instance["status"]),
              name: instance["displayName"] || opts[:name]
            }}

          {:ok, %{"data" => instance}} when is_map(instance) ->
            ip = get_in(instance, ["ipConfig", "v4", "ip"])
            {:ok, %{
              external_id: to_string(instance["instanceId"]),
              ip_address: ip,
              status: normalize_status(instance["status"]),
              name: instance["displayName"] || opts[:name]
            }}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, {:auth_failed, reason}}
    end
  end

  @impl true
  def destroy_server(credentials, external_id) do
    case get_access_token(credentials) do
      {:ok, token} ->
        case api_delete(token, "/compute/instances/#{external_id}") do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, {:auth_failed, reason}}
    end
  end

  @impl true
  def get_server(credentials, external_id) do
    case get_access_token(credentials) do
      {:ok, token} ->
        case api_get(token, "/compute/instances/#{external_id}") do
          {:ok, %{"data" => [instance | _]}} ->
            ip = get_in(instance, ["ipConfig", "v4", "ip"])
            {:ok, %{
              external_id: to_string(instance["instanceId"]),
              ip_address: ip,
              status: normalize_status(instance["status"]),
              name: instance["displayName"]
            }}

          {:ok, %{"data" => instance}} when is_map(instance) ->
            ip = get_in(instance, ["ipConfig", "v4", "ip"])
            {:ok, %{
              external_id: to_string(instance["instanceId"]),
              ip_address: ip,
              status: normalize_status(instance["status"]),
              name: instance["displayName"]
            }}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, {:auth_failed, reason}}
    end
  end

  # ── OAuth2 token exchange ────────────────────────────────

  defp get_access_token(credentials) do
    body = URI.encode_query(%{
      "client_id" => credentials["client_id"] || credentials[:client_id],
      "client_secret" => credentials["client_secret"] || credentials[:client_secret],
      "username" => credentials["api_user"] || credentials[:api_user],
      "password" => credentials["api_password"] || credentials[:api_password],
      "grant_type" => "password"
    })

    headers = [{"Content-Type", "application/x-www-form-urlencoded"}]

    case :hackney.request(:post, @auth_url, headers, body, [recv_timeout: 15_000]) do
      {:ok, 200, _headers, ref} ->
        {:ok, resp} = :hackney.body(ref)
        case Jason.decode(resp) do
          {:ok, %{"access_token" => token}} -> {:ok, token}
          _ -> {:error, :invalid_token_response}
        end

      {:ok, status, _headers, ref} ->
        {:ok, resp} = :hackney.body(ref)
        {:error, %{status: status, body: resp}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Private helpers ──────────────────────────────────────

  defp api_get(token, path) do
    url = @base_url <> path
    headers = [{"Authorization", "Bearer #{token}"}, {"x-request-id", request_id()}]

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

  defp api_post(token, path, body) do
    url = @base_url <> path
    headers = [
      {"Content-Type", "application/json"},
      {"Authorization", "Bearer #{token}"},
      {"x-request-id", request_id()}
    ]

    case :hackney.request(:post, url, headers, Jason.encode!(body), [recv_timeout: 30_000]) do
      {:ok, status, _headers, ref} when status in 200..299 ->
        {:ok, resp} = :hackney.body(ref)
        {:ok, Jason.decode!(resp)}

      {:ok, status, _headers, ref} ->
        {:ok, resp} = :hackney.body(ref)
        {:error, %{status: status, body: resp}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp api_delete(token, path) do
    url = @base_url <> path
    headers = [{"Authorization", "Bearer #{token}"}, {"x-request-id", request_id()}]

    case :hackney.request(:delete, url, headers, "", [recv_timeout: 15_000]) do
      {:ok, status, _headers, _ref} when status in [200, 204] ->
        {:ok, %{}}

      {:ok, status, _headers, ref} ->
        {:ok, body} = :hackney.body(ref)
        {:error, %{status: status, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request_id, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

  defp normalize_status("running"), do: "running"
  defp normalize_status("provisioning"), do: "provisioning"
  defp normalize_status("installing"), do: "provisioning"
  defp normalize_status("stopped"), do: "stopped"
  defp normalize_status("cancelled"), do: "destroyed"
  defp normalize_status(_), do: "error"
end
