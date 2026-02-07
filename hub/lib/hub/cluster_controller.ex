defmodule Hub.ClusterController do
  @moduledoc """
  Cluster health and status endpoint.

  Returns information about all connected BEAM nodes, their status,
  agent counts, and region tags. Protected by admin authentication.
  """
  use Phoenix.Controller, formats: [:json]

  @doc """
  GET /api/cluster/health

  Returns cluster status including all connected nodes, agent distribution,
  and region information.
  """
  def health(conn, _params) do
    current_node = Hub.NodeInfo.to_map()
    connected = Hub.Cluster.connected_nodes()

    # Count agents on this node (approximate — presence tracked agents)
    local_agent_count = count_local_agents()

    nodes =
      [
        %{
          node: Hub.NodeInfo.node_name_string(),
          status: "running",
          region: Hub.NodeInfo.region(),
          agents: local_agent_count,
          started_at: DateTime.to_iso8601(Hub.NodeInfo.started_at()),
          self: true
        }
        | Enum.map(connected, fn node ->
            %{
              node: Atom.to_string(node),
              status: "connected",
              region: rpc_region(node),
              agents: rpc_agent_count(node),
              self: false
            }
          end)
      ]

    json(conn, %{
      status: "healthy",
      strategy: Hub.Cluster.strategy(),
      cluster_size: Hub.NodeInfo.cluster_size(),
      current_node: current_node,
      nodes: nodes,
      total_agents: Enum.reduce(nodes, 0, fn n, acc -> acc + (n.agents || 0) end),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  # ── Private ───────────────────────────────────────────────

  defp count_local_agents do
    # Count distinct agents across all fleet presence topics
    try do
      # This is an approximation — counts all tracked presences
      :ets.info(Hub.FleetPresence, :size) || 0
    rescue
      _ -> 0
    catch
      _, _ -> 0
    end
  end

  defp rpc_region(node) do
    case :rpc.call(node, Hub.Cluster, :region, [], 5_000) do
      {:badrpc, _} -> "unknown"
      region -> region
    end
  end

  defp rpc_agent_count(node) do
    case :rpc.call(node, :ets, :info, [Hub.FleetPresence, :size], 5_000) do
      {:badrpc, _} -> 0
      nil -> 0
      count -> count
    end
  end
end
