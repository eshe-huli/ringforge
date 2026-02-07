defmodule Hub.ProvisioningController do
  @moduledoc """
  REST controller for cloud provider credentials and agent provisioning.

  All actions are scoped to the authenticated admin's tenant.
  """
  use Phoenix.Controller, formats: [:json]

  alias Hub.Provisioning
  alias Hub.Providers.Provider

  # ═══════════════════════════════════════════════════════════
  # Provider Credentials
  # ═══════════════════════════════════════════════════════════

  @doc "POST /api/v1/providers — Save provider credentials."
  def create_credential(conn, params) do
    tenant_id = conn.assigns.tenant_id

    case Provisioning.save_credentials(tenant_id, params) do
      {:ok, cred} ->
        conn
        |> put_status(201)
        |> json(%{
          id: cred.id,
          provider: cred.provider,
          name: cred.name,
          active: cred.active,
          inserted_at: cred.inserted_at
        })

      {:error, changeset} ->
        errors = format_errors(changeset)
        conn |> put_status(400) |> json(%{error: "validation_failed", details: errors})
    end
  end

  @doc "GET /api/v1/providers — List credentials (masked)."
  def list_credentials(conn, _params) do
    tenant_id = conn.assigns.tenant_id
    credentials = Provisioning.list_credentials(tenant_id)

    json(conn, %{
      credentials: Enum.map(credentials, &credential_json/1),
      count: length(credentials)
    })
  end

  @doc "DELETE /api/v1/providers/:id — Delete credentials."
  def delete_credential(conn, %{"id" => id}) do
    tenant_id = conn.assigns.tenant_id

    case Provisioning.delete_credentials(id, tenant_id) do
      {:ok, _} ->
        json(conn, %{status: "deleted"})

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "not_found"})

      {:error, :credentials_in_use} ->
        conn |> put_status(409) |> json(%{error: "credentials_in_use", message: "Active agents are using these credentials"})

      {:error, _} ->
        conn |> put_status(500) |> json(%{error: "delete_failed"})
    end
  end

  # ═══════════════════════════════════════════════════════════
  # Provisioned Agents
  # ═══════════════════════════════════════════════════════════

  @doc "POST /api/v1/agents/provision — Provision a new agent."
  def provision_agent(conn, params) do
    tenant_id = conn.assigns.tenant_id
    fleet_id = conn.assigns.fleet_id
    credential_id = params["credential_id"]

    if is_nil(credential_id) do
      conn |> put_status(400) |> json(%{error: "credential_id is required"})
    else
      case Provisioning.provision_agent(tenant_id, fleet_id, credential_id, params) do
        {:ok, agent} ->
          conn |> put_status(201) |> json(agent_json(agent))

        {:error, :rate_limited} ->
          conn |> put_status(429) |> json(%{error: "rate_limited", message: "Max 5 concurrent provisions per tenant"})

        {:error, :credential_not_found} ->
          conn |> put_status(404) |> json(%{error: "credential_not_found"})

        {:error, changeset} ->
          errors = format_errors(changeset)
          conn |> put_status(400) |> json(%{error: "validation_failed", details: errors})
      end
    end
  end

  @doc "DELETE /api/v1/agents/provision/:id — Destroy a provisioned agent."
  def destroy_agent(conn, %{"id" => id}) do
    tenant_id = conn.assigns.tenant_id

    case Provisioning.destroy_agent(id, tenant_id) do
      {:ok, _} ->
        json(conn, %{status: "destroying"})

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "not_found"})

      {:error, :already_destroyed} ->
        conn |> put_status(409) |> json(%{error: "already_destroyed"})

      {:error, _} ->
        conn |> put_status(500) |> json(%{error: "destroy_failed"})
    end
  end

  @doc "GET /api/v1/agents/provision — List provisioned agents."
  def list_agents(conn, _params) do
    tenant_id = conn.assigns.tenant_id
    agents = Provisioning.list_agents(tenant_id)
    total_cost = Provisioning.total_monthly_cost(tenant_id)

    json(conn, %{
      agents: Enum.map(agents, &agent_json/1),
      count: length(agents),
      total_monthly_cost_cents: total_cost
    })
  end

  @doc "GET /api/v1/agents/provision/:id/status — Get agent status."
  def agent_status(conn, %{"id" => id}) do
    tenant_id = conn.assigns.tenant_id

    case Provisioning.get_agent(id, tenant_id) do
      nil ->
        conn |> put_status(404) |> json(%{error: "not_found"})

      agent ->
        json(conn, %{
          id: agent.id,
          name: agent.name,
          status: agent.status,
          ip_address: agent.ip_address,
          provider: agent.provider,
          external_id: agent.external_id,
          error_message: agent.error_message
        })
    end
  end

  @doc "GET /api/v1/providers/regions/:provider — List regions for a provider."
  def list_regions(conn, %{"provider" => provider}) do
    _tenant_id = conn.assigns.tenant_id
    case Provider.module_for(provider) do
      {:error, _} ->
        conn |> put_status(400) |> json(%{error: "unknown_provider"})

      provider_mod ->
        case provider_mod.list_regions(%{}) do
          {:ok, regions} -> json(conn, %{regions: regions})
          {:error, reason} -> conn |> put_status(500) |> json(%{error: inspect(reason)})
        end
    end
  end

  @doc "GET /api/v1/providers/sizes/:provider — List sizes for a provider."
  def list_sizes(conn, %{"provider" => provider}) do
    case Provider.module_for(provider) do
      {:error, _} ->
        conn |> put_status(400) |> json(%{error: "unknown_provider"})

      provider_mod ->
        case provider_mod.list_sizes(%{}) do
          {:ok, sizes} -> json(conn, %{sizes: sizes})
          {:error, reason} -> conn |> put_status(500) |> json(%{error: inspect(reason)})
        end
    end
  end

  # ═══════════════════════════════════════════════════════════
  # JSON Helpers
  # ═══════════════════════════════════════════════════════════

  defp credential_json(cred) do
    %{
      id: cred.id,
      provider: cred.provider,
      name: cred.name,
      credentials: cred.credentials,
      active: cred.active,
      inserted_at: cred.inserted_at
    }
  end

  defp agent_json(agent) do
    %{
      id: agent.id,
      provider: agent.provider,
      name: agent.name,
      status: agent.status,
      region: agent.region,
      size: agent.size,
      template: agent.template,
      ip_address: agent.ip_address,
      external_id: agent.external_id,
      monthly_cost_cents: agent.monthly_cost_cents,
      error_message: agent.error_message,
      provisioned_at: agent.provisioned_at,
      inserted_at: agent.inserted_at
    }
  end

  defp format_errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
  defp format_errors(error), do: %{error: inspect(error)}
end
