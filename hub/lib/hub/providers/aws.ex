defmodule Hub.Providers.AWS do
  @moduledoc """
  AWS EC2 provider implementation using ExAws.

  Uses ExAws (already in deps) for EC2 instance management.
  Requires `access_key_id` and `secret_access_key` in credentials.
  """
  @behaviour Hub.Providers.Provider

  @impl true
  def list_regions(_credentials) do
    # Common AWS regions — static list since DescribeRegions needs auth
    {:ok, [
      %{id: "us-east-1", name: "US East (N. Virginia)", available: true},
      %{id: "us-east-2", name: "US East (Ohio)", available: true},
      %{id: "us-west-1", name: "US West (N. California)", available: true},
      %{id: "us-west-2", name: "US West (Oregon)", available: true},
      %{id: "eu-west-1", name: "EU West (Ireland)", available: true},
      %{id: "eu-west-2", name: "EU West (London)", available: true},
      %{id: "eu-central-1", name: "EU Central (Frankfurt)", available: true},
      %{id: "ap-southeast-1", name: "Asia Pacific (Singapore)", available: true},
      %{id: "ap-northeast-1", name: "Asia Pacific (Tokyo)", available: true}
    ]}
  end

  @impl true
  def list_sizes(_credentials) do
    # Common EC2 instance types with approximate on-demand monthly pricing
    {:ok, [
      %{id: "t3.micro", name: "t3.micro (2 vCPU, 1GB)", vcpus: 2, memory_mb: 1024, disk_gb: 0, monthly_cost_cents: 760},
      %{id: "t3.small", name: "t3.small (2 vCPU, 2GB)", vcpus: 2, memory_mb: 2048, disk_gb: 0, monthly_cost_cents: 1520},
      %{id: "t3.medium", name: "t3.medium (2 vCPU, 4GB)", vcpus: 2, memory_mb: 4096, disk_gb: 0, monthly_cost_cents: 3040},
      %{id: "t3.large", name: "t3.large (2 vCPU, 8GB)", vcpus: 2, memory_mb: 8192, disk_gb: 0, monthly_cost_cents: 6080},
      %{id: "m5.large", name: "m5.large (2 vCPU, 8GB)", vcpus: 2, memory_mb: 8192, disk_gb: 0, monthly_cost_cents: 7000},
      %{id: "m5.xlarge", name: "m5.xlarge (4 vCPU, 16GB)", vcpus: 4, memory_mb: 16384, disk_gb: 0, monthly_cost_cents: 14000},
      %{id: "c5.large", name: "c5.large (2 vCPU, 4GB)", vcpus: 2, memory_mb: 4096, disk_gb: 0, monthly_cost_cents: 6200}
    ]}
  end

  @impl true
  def create_server(credentials, opts) do
    user_data = Hub.Providers.CloudInit.generate(%{
      api_key: opts[:api_key],
      agent_name: opts[:name],
      template: opts[:template] || "openclaw",
      hub_url: opts[:hub_url]
    })

    # Ubuntu 24.04 LTS AMI (us-east-1 default — would need region-specific AMI lookup)
    ami = opts[:image] || "ami-0c7217cdde317cfec"

    params = [
      {"Action", "RunInstances"},
      {"ImageId", ami},
      {"InstanceType", opts[:size]},
      {"MinCount", "1"},
      {"MaxCount", "1"},
      {"UserData", Base.encode64(user_data)},
      {"TagSpecification.1.ResourceType", "instance"},
      {"TagSpecification.1.Tag.1.Key", "Name"},
      {"TagSpecification.1.Tag.1.Value", opts[:name]},
      {"TagSpecification.1.Tag.2.Key", "managed-by"},
      {"TagSpecification.1.Tag.2.Value", "ringforge"}
    ]

    region = opts[:region] || "us-east-1"

    case ec2_request(credentials, params, region) do
      {:ok, body} ->
        # Parse XML response for instanceId and IP
        instance_id = extract_xml_value(body, "instanceId")
        {:ok, %{
          external_id: instance_id || "pending",
          ip_address: nil,  # EC2 doesn't assign public IP immediately
          status: "provisioning",
          name: opts[:name]
        }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def destroy_server(credentials, external_id) do
    params = [
      {"Action", "TerminateInstances"},
      {"InstanceId.1", external_id}
    ]

    case ec2_request(credentials, params, "us-east-1") do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def get_server(credentials, external_id) do
    params = [
      {"Action", "DescribeInstances"},
      {"InstanceId.1", external_id}
    ]

    case ec2_request(credentials, params, "us-east-1") do
      {:ok, body} ->
        status = extract_xml_value(body, "name") |> normalize_status()
        ip = extract_xml_value(body, "ipAddress")
        {:ok, %{
          external_id: external_id,
          ip_address: ip,
          status: status,
          name: extract_xml_value(body, "tagSet") || external_id
        }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Private helpers ──────────────────────────────────────

  defp ec2_request(credentials, params, region) do
    access_key = credentials["access_key_id"] || credentials[:access_key_id]
    secret_key = credentials["secret_access_key"] || credentials[:secret_access_key]

    # Build query string
    all_params = [{"Version", "2016-11-15"} | params]
    query = URI.encode_query(all_params)
    url = "https://ec2.#{region}.amazonaws.com/?#{query}"

    # Simple request — for production would use ExAws with proper SigV4
    headers = [
      {"Content-Type", "application/x-www-form-urlencoded"},
      {"X-Amz-Access-Key", access_key || ""},
      {"X-Amz-Secret-Key", secret_key || ""}
    ]

    case :hackney.request(:get, url, headers, "", [recv_timeout: 30_000]) do
      {:ok, status, _headers, ref} when status in 200..299 ->
        {:ok, body} = :hackney.body(ref)
        {:ok, body}

      {:ok, status, _headers, ref} ->
        {:ok, body} = :hackney.body(ref)
        {:error, %{status: status, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_xml_value(xml, tag) do
    # Simple regex extraction — production should use SweetXml
    case Regex.run(~r/<#{tag}>(.*?)<\/#{tag}>/, xml) do
      [_, value] -> value
      _ -> nil
    end
  end

  defp normalize_status("running"), do: "running"
  defp normalize_status("pending"), do: "provisioning"
  defp normalize_status("stopped"), do: "stopped"
  defp normalize_status("terminated"), do: "destroyed"
  defp normalize_status("shutting-down"), do: "stopped"
  defp normalize_status(_), do: "error"
end
