defmodule Hub.Provisioning do
  @moduledoc """
  Context module for agent provisioning.

  Handles CRUD for provider credentials and provisioned agents,
  with encryption, tenant isolation, and rate limiting.
  """

  import Ecto.Query
  alias Hub.Repo
  alias Hub.Schemas.{ProviderCredential, ProvisionedAgent}
  alias Hub.Providers.{CredentialEncryption, Provider}

  @max_concurrent_provisions 5

  # ═══════════════════════════════════════════════════════════
  # Provider Credentials
  # ═══════════════════════════════════════════════════════════

  @doc "Save provider credentials (encrypts sensitive fields)."
  def save_credentials(tenant_id, attrs) do
    raw_creds = attrs[:credentials] || attrs["credentials"] || %{}
    encrypted = CredentialEncryption.encrypt(raw_creds)

    params = %{
      tenant_id: tenant_id,
      provider: attrs[:provider] || attrs["provider"],
      name: attrs[:name] || attrs["name"],
      credentials: encrypted,
      active: Map.get(attrs, :active, Map.get(attrs, "active", true))
    }

    %ProviderCredential{}
    |> ProviderCredential.changeset(params)
    |> Repo.insert()
  end

  @doc "List provider credentials for a tenant (credentials are masked)."
  def list_credentials(tenant_id) do
    ProviderCredential
    |> where(tenant_id: ^tenant_id)
    |> order_by([c], desc: c.inserted_at)
    |> Repo.all()
    |> Enum.map(&mask_credential/1)
  end

  @doc "Get a credential by ID with tenant isolation."
  def get_credential(id, tenant_id) do
    ProviderCredential
    |> where(id: ^id, tenant_id: ^tenant_id)
    |> Repo.one()
  end

  @doc "Get decrypted credentials for a credential record."
  def decrypt_credential(%ProviderCredential{credentials: encrypted}) do
    CredentialEncryption.decrypt(encrypted)
  end

  @doc "Delete provider credentials by ID with tenant isolation."
  def delete_credentials(id, tenant_id) do
    case get_credential(id, tenant_id) do
      nil -> {:error, :not_found}
      cred ->
        # Check if any non-destroyed agents use this credential
        active_count = ProvisionedAgent
          |> where(provider_credential_id: ^id)
          |> where([a], a.status not in ["destroyed", "error"])
          |> Repo.aggregate(:count)

        if active_count > 0 do
          {:error, :credentials_in_use}
        else
          Repo.delete(cred)
        end
    end
  end

  # ═══════════════════════════════════════════════════════════
  # Provisioned Agents
  # ═══════════════════════════════════════════════════════════

  @doc "Provision a new agent on a cloud provider."
  def provision_agent(tenant_id, fleet_id, credential_id, opts) do
    # Rate limit check
    active_provisions = ProvisionedAgent
      |> where(tenant_id: ^tenant_id, status: "provisioning")
      |> Repo.aggregate(:count)

    if active_provisions >= @max_concurrent_provisions do
      {:error, :rate_limited}
    else
      credential = get_credential(credential_id, tenant_id)
      if is_nil(credential) do
        {:error, :credential_not_found}
      else
        # Generate API key for the agent
        api_key = generate_agent_api_key()

        params = %{
          tenant_id: tenant_id,
          fleet_id: fleet_id,
          provider_credential_id: credential_id,
          provider: credential.provider,
          name: opts[:name] || opts["name"],
          region: opts[:region] || opts["region"],
          size: opts[:size] || opts["size"],
          template: opts[:template] || opts["template"] || "openclaw",
          agent_api_key: api_key,
          monthly_cost_cents: opts[:monthly_cost_cents] || opts["monthly_cost_cents"] || 0,
          status: "provisioning"
        }

        case %ProvisionedAgent{} |> ProvisionedAgent.changeset(params) |> Repo.insert() do
          {:ok, agent} ->
            # Dispatch async provisioning
            Hub.ProvisioningWorker.provision(agent)
            {:ok, agent}

          {:error, changeset} ->
            {:error, changeset}
        end
      end
    end
  end

  @doc "Destroy a provisioned agent."
  def destroy_agent(id, tenant_id) do
    case get_agent(id, tenant_id) do
      nil -> {:error, :not_found}
      agent ->
        if agent.status == "destroyed" do
          {:error, :already_destroyed}
        else
          Hub.ProvisioningWorker.destroy(agent)
          {:ok, agent}
        end
    end
  end

  @doc "List provisioned agents for a tenant."
  def list_agents(tenant_id) do
    ProvisionedAgent
    |> where(tenant_id: ^tenant_id)
    |> order_by([a], desc: a.inserted_at)
    |> preload(:provider_credential)
    |> Repo.all()
  end

  @doc "Get a provisioned agent by ID with tenant isolation."
  def get_agent(id, tenant_id) do
    ProvisionedAgent
    |> where(id: ^id, tenant_id: ^tenant_id)
    |> preload(:provider_credential)
    |> Repo.one()
  end

  @doc "Sync status of a provisioned agent from the provider."
  def sync_status(%ProvisionedAgent{} = agent) do
    credential = get_credential(agent.provider_credential_id, agent.tenant_id)
    if is_nil(credential) do
      {:error, :credential_not_found}
    else
      case decrypt_credential(credential) do
        {:ok, creds} ->
          provider_mod = Provider.module_for(agent.provider)
          case provider_mod.get_server(creds, agent.external_id) do
            {:ok, info} ->
              update_agent_status(agent, %{
                status: info.status,
                ip_address: info.ip_address
              })

            {:error, reason} ->
              {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "Update a provisioned agent's status fields."
  def update_agent_status(%ProvisionedAgent{} = agent, attrs) do
    agent
    |> ProvisionedAgent.status_changeset(attrs)
    |> Repo.update()
  end

  @doc "Available agent templates."
  def get_templates do
    [
      %{id: "openclaw", name: "OpenClaw Agent", description: "Full-featured agent with tool support and Docker"},
      %{id: "bare", name: "Bare Agent", description: "Minimal agent — connects to mesh only"},
      %{id: "custom", name: "Custom", description: "Manual setup — cloud-init installs Docker only"}
    ]
  end

  @doc "Get total monthly cost for a tenant's running agents."
  def total_monthly_cost(tenant_id) do
    ProvisionedAgent
    |> where(tenant_id: ^tenant_id)
    |> where([a], a.status in ["provisioning", "running"])
    |> Repo.aggregate(:sum, :monthly_cost_cents) || 0
  end

  # ═══════════════════════════════════════════════════════════
  # Private Helpers
  # ═══════════════════════════════════════════════════════════

  defp mask_credential(%ProviderCredential{} = cred) do
    # For display — decrypt then mask, or show raw masked
    masked = case CredentialEncryption.decrypt(cred.credentials) do
      {:ok, decrypted} -> CredentialEncryption.mask(decrypted)
      _ -> %{"status" => "encrypted"}
    end
    %{cred | credentials: masked}
  end

  defp generate_agent_api_key do
    "rf_prov_" <> (:crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false))
  end
end
