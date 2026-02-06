defmodule Hub.AgentController do
  @moduledoc """
  Admin REST controller for agent management.

  Lists and manages agents scoped to the authenticated admin's tenant,
  enriched with online presence status from FleetPresence.
  """

  use Phoenix.Controller, formats: [:json]

  import Ecto.Query

  alias Hub.Repo
  alias Hub.Auth.Agent
  alias Hub.FleetPresence

  @doc "GET /api/v1/agents — List agents for tenant with online status."
  def index(conn, _params) do
    tenant_id = conn.assigns.tenant_id

    agents =
      from(a in Agent,
        where: a.tenant_id == ^tenant_id,
        order_by: [desc: a.inserted_at],
        preload: [:fleet]
      )
      |> Repo.all()
      |> Enum.map(fn agent -> agent_json(agent) end)

    json(conn, %{agents: agents, count: length(agents)})
  end

  @doc "GET /api/v1/agents/:agent_id — Get agent details + presence state."
  def show(conn, %{"id" => agent_id}) do
    tenant_id = conn.assigns.tenant_id

    case Repo.get_by(Agent, agent_id: agent_id) do
      %Agent{tenant_id: ^tenant_id} = agent ->
        agent = Repo.preload(agent, [:fleet])
        json(conn, agent_json(agent))

      %Agent{} ->
        conn |> put_status(403) |> json(%{error: "forbidden", message: "Access denied"})

      nil ->
        # Also try by DB id
        case Repo.get(Agent, agent_id) do
          %Agent{tenant_id: ^tenant_id} = agent ->
            agent = Repo.preload(agent, [:fleet])
            json(conn, agent_json(agent))

          _ ->
            conn |> put_status(404) |> json(%{error: "not_found", message: "Agent not found"})
        end
    end
  end

  @doc "DELETE /api/v1/agents/:agent_id — Remove agent record."
  def delete(conn, %{"id" => agent_id}) do
    tenant_id = conn.assigns.tenant_id

    agent =
      Repo.get_by(Agent, agent_id: agent_id) || Repo.get(Agent, agent_id)

    case agent do
      %Agent{tenant_id: ^tenant_id} = a ->
        case Repo.delete(a) do
          {:ok, _} ->
            json(conn, %{deleted: true, agent_id: a.agent_id})

          {:error, _} ->
            conn |> put_status(500) |> json(%{error: "delete_failed"})
        end

      %Agent{} ->
        conn |> put_status(403) |> json(%{error: "forbidden", message: "Access denied"})

      nil ->
        conn |> put_status(404) |> json(%{error: "not_found", message: "Agent not found"})
    end
  end

  # ── Helpers ────────────────────────────────────────────────

  defp agent_json(agent) do
    presence = get_presence(agent)

    %{
      id: agent.id,
      agent_id: agent.agent_id,
      name: agent.name,
      framework: agent.framework,
      capabilities: agent.capabilities,
      fleet_id: agent.fleet_id,
      fleet_name: if(agent.fleet, do: agent.fleet.name),
      last_seen_at: agent.last_seen_at,
      inserted_at: agent.inserted_at,
      online: presence != nil,
      presence: presence
    }
  end

  defp get_presence(agent) do
    topic = "fleet:#{agent.fleet_id}"

    case FleetPresence.list(topic) do
      presences when is_map(presences) ->
        case Map.get(presences, agent.agent_id) do
          %{metas: [meta | _]} ->
            %{
              state: meta[:state],
              task: meta[:task],
              load: meta[:load],
              connected_at: meta[:connected_at]
            }

          _ ->
            nil
        end

      _ ->
        nil
    end
  end
end
