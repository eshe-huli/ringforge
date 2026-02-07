defmodule Hub.ProvisioningWorker do
  @moduledoc """
  GenServer that handles async provisioning operations.

  - Processes provision/destroy requests asynchronously
  - Updates agent status (provisioning → running or error)
  - Periodic status sync every 5 minutes for running agents
  """
  use GenServer
  require Logger

  alias Hub.Provisioning
  alias Hub.Providers.{Provider, CredentialEncryption}
  alias Hub.Schemas.ProvisionedAgent

  @sync_interval :timer.minutes(5)

  # ═══════════════════════════════════════════════════════════
  # Client API
  # ═══════════════════════════════════════════════════════════

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Queue a provision request."
  def provision(%ProvisionedAgent{} = agent) do
    GenServer.cast(__MODULE__, {:provision, agent})
  end

  @doc "Queue a destroy request."
  def destroy(%ProvisionedAgent{} = agent) do
    GenServer.cast(__MODULE__, {:destroy, agent})
  end

  # ═══════════════════════════════════════════════════════════
  # Server Callbacks
  # ═══════════════════════════════════════════════════════════

  @impl true
  def init(_opts) do
    schedule_sync()
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:provision, agent}, state) do
    Task.start(fn -> do_provision(agent) end)
    {:noreply, state}
  end

  def handle_cast({:destroy, agent}, state) do
    Task.start(fn -> do_destroy(agent) end)
    {:noreply, state}
  end

  @impl true
  def handle_info(:sync_statuses, state) do
    Task.start(fn -> do_sync_all() end)
    schedule_sync()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ═══════════════════════════════════════════════════════════
  # Private Implementation
  # ═══════════════════════════════════════════════════════════

  defp do_provision(agent) do
    Logger.info("[Provisioning] Starting provision for #{agent.name} (#{agent.provider})")

    credential = Provisioning.get_credential(agent.provider_credential_id, agent.tenant_id)
    if is_nil(credential) do
      Provisioning.update_agent_status(agent, %{
        status: "error",
        error_message: "Provider credential not found"
      })
      broadcast_status(agent, "error")
      :error
    else
      case CredentialEncryption.decrypt(credential.credentials) do
        {:ok, creds} ->
          provider_mod = Provider.module_for(agent.provider)
          opts = %{
            name: agent.name,
            region: agent.region,
            size: agent.size,
            template: agent.template,
            api_key: agent.agent_api_key,
            fleet_id: agent.fleet_id,
            hub_url: System.get_env("RINGFORGE_HUB_URL", "wss://hub.ringforge.io/socket")
          }

          case provider_mod.create_server(creds, opts) do
            {:ok, info} ->
              now = DateTime.utc_now() |> DateTime.truncate(:second)
              Provisioning.update_agent_status(agent, %{
                status: info.status || "running",
                external_id: info.external_id,
                ip_address: info.ip_address,
                provisioned_at: now
              })
              Logger.info("[Provisioning] Agent #{agent.name} provisioned: #{info.external_id}")
              broadcast_status(agent, info.status || "running")
              :ok

            {:error, reason} ->
              error_msg = inspect(reason, limit: 500)
              Provisioning.update_agent_status(agent, %{
                status: "error",
                error_message: error_msg
              })
              Logger.error("[Provisioning] Failed to provision #{agent.name}: #{error_msg}")
              broadcast_status(agent, "error")
              :error
          end

        {:error, reason} ->
          Provisioning.update_agent_status(agent, %{
            status: "error",
            error_message: "Credential decryption failed: #{inspect(reason)}"
          })
          broadcast_status(agent, "error")
          :error
      end
    end
  end

  defp do_destroy(agent) do
    Logger.info("[Provisioning] Destroying agent #{agent.name} (#{agent.external_id})")

    if is_nil(agent.external_id) do
      Provisioning.update_agent_status(agent, %{status: "destroyed"})
      broadcast_status(agent, "destroyed")
      :ok
    else
      credential = Provisioning.get_credential(agent.provider_credential_id, agent.tenant_id)
      if is_nil(credential) do
        # Credential deleted — mark as destroyed anyway
        Provisioning.update_agent_status(agent, %{status: "destroyed"})
        broadcast_status(agent, "destroyed")
        :ok
      else
        case CredentialEncryption.decrypt(credential.credentials) do
          {:ok, creds} ->
            provider_mod = Provider.module_for(agent.provider)
            case provider_mod.destroy_server(creds, agent.external_id) do
              :ok ->
                Provisioning.update_agent_status(agent, %{status: "destroyed"})
                Logger.info("[Provisioning] Agent #{agent.name} destroyed")
                broadcast_status(agent, "destroyed")
                :ok

              {:error, reason} ->
                Logger.error("[Provisioning] Failed to destroy #{agent.name}: #{inspect(reason)}")
                Provisioning.update_agent_status(agent, %{
                  status: "error",
                  error_message: "Destroy failed: #{inspect(reason, limit: 200)}"
                })
                broadcast_status(agent, "error")
                :error
            end

          {:error, _} ->
            Provisioning.update_agent_status(agent, %{status: "destroyed"})
            broadcast_status(agent, "destroyed")
            :ok
        end
      end
    end
  end

  defp do_sync_all do
    import Ecto.Query

    agents = Hub.Schemas.ProvisionedAgent
      |> where([a], a.status in ["provisioning", "running"])
      |> where([a], not is_nil(a.external_id))
      |> Hub.Repo.all()

    Enum.each(agents, fn agent ->
      case Provisioning.sync_status(agent) do
        {:ok, updated} ->
          if updated.status != agent.status do
            Logger.info("[Provisioning] Status sync: #{agent.name} #{agent.status} → #{updated.status}")
            broadcast_status(updated, updated.status)
          end

        {:error, reason} ->
          Logger.warning("[Provisioning] Status sync failed for #{agent.name}: #{inspect(reason)}")
      end
    end)
  end

  defp schedule_sync do
    Process.send_after(self(), :sync_statuses, @sync_interval)
  end

  defp broadcast_status(agent, status) do
    Phoenix.PubSub.broadcast(
      Hub.PubSub,
      "provisioning:#{agent.tenant_id}",
      {:provisioned_agent_updated, %{id: agent.id, status: status, name: agent.name}}
    )
  end
end
