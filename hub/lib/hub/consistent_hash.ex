defmodule Hub.ConsistentHash do
  @moduledoc """
  Consistent hashing ring for agent-to-node assignment.

  When multiple Hub nodes exist, agents are assigned a "preferred" node
  using consistent hashing on their agent_id. This enables:

  - Sticky sessions: LB can route agents to their preferred node
  - Predictable distribution: agents land on the same node after reconnect
  - Graceful redistribution: when a node leaves, only its agents move

  Uses a virtual-node approach with 128 vnodes per physical node for
  uniform distribution.
  """

  @vnodes_per_node 128

  @doc """
  Given a set of node names and an agent_id, return the preferred node.

  Returns the current node if the cluster has only one node or the ring is empty.

  ## Examples

      iex> Hub.ConsistentHash.preferred_node([:hub1, :hub2, :hub3], "ag_abc123")
      :hub2
  """
  def preferred_node([], _agent_id), do: Node.self()
  def preferred_node([single], _agent_id), do: single

  def preferred_node(nodes, agent_id) when is_list(nodes) do
    ring = build_ring(nodes)
    hash = hash_key(agent_id)

    # Find the first vnode with a hash >= agent hash (clockwise walk)
    case Enum.find(ring, fn {vhash, _node} -> vhash >= hash end) do
      {_vhash, node} -> node
      nil ->
        # Wrap around — use the first vnode in the ring
        {_vhash, node} = hd(ring)
        node
    end
  end

  @doc """
  Preferred node for an agent using the current cluster state.
  """
  def preferred_node_for(agent_id) do
    nodes = Hub.Cluster.all_nodes()
    preferred_node(nodes, agent_id)
  end

  @doc """
  Returns true if this node is the preferred node for the given agent.
  """
  def is_preferred?(agent_id) do
    preferred_node_for(agent_id) == Node.self()
  end

  @doc """
  Partition a list of agent IDs by their preferred node.

  Returns `%{node => [agent_ids]}`.
  """
  def partition_agents(agent_ids, nodes \\ nil) do
    nodes = nodes || Hub.Cluster.all_nodes()

    Enum.group_by(agent_ids, fn agent_id ->
      preferred_node(nodes, agent_id)
    end)
  end

  # ── Private ───────────────────────────────────────────────

  defp build_ring(nodes) do
    nodes
    |> Enum.flat_map(fn node ->
      for i <- 0..(@vnodes_per_node - 1) do
        vnode_key = "#{node}:#{i}"
        {hash_key(vnode_key), node}
      end
    end)
    |> Enum.sort_by(fn {hash, _node} -> hash end)
  end

  defp hash_key(key) when is_binary(key) do
    :erlang.phash2(key, 2_147_483_647)
  end

  defp hash_key(key), do: hash_key(to_string(key))
end
