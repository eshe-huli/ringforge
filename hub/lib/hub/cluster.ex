defmodule Hub.Cluster do
  @moduledoc """
  Cluster topology configuration for multi-node BEAM deployments.

  Supports multiple discovery strategies, configurable via the
  `CLUSTER_STRATEGY` environment variable:

  - `"none"` (default) — standalone mode, no clustering
  - `"gossip"` — UDP multicast gossip for dev/VPS deployments
  - `"dns"` — DNS polling for Kubernetes / Fly.io
  - `"epmd"` — static host list for local multi-node dev

  All clustering features are opt-in. The default single-node experience
  is fully preserved when no strategy is configured.
  """

  @doc """
  Build the libcluster topology from application config.

  Returns `[]` when strategy is `"none"` (standalone mode), which causes
  the Cluster.Supervisor to start without joining any cluster.
  """
  def topologies do
    config = Application.get_env(:hub, __MODULE__, [])
    strategy = Keyword.get(config, :strategy, "none")

    case strategy do
      "none" ->
        []

      "gossip" ->
        [
          hub: [
            strategy: Cluster.Strategy.Gossip,
            config: [
              port: Keyword.get(config, :gossip_port, 45892),
              if_addr: Keyword.get(config, :gossip_if_addr, "0.0.0.0"),
              multicast_addr: Keyword.get(config, :gossip_multicast_addr, "230.1.1.251"),
              multicast_ttl: Keyword.get(config, :gossip_multicast_ttl, 1)
            ]
          ]
        ]

      "dns" ->
        [
          hub: [
            strategy: Cluster.Strategy.DNSPoll,
            config: [
              polling_interval: Keyword.get(config, :dns_poll_interval, 5_000),
              query: Keyword.get(config, :dns_query, "ringforge-hub.internal"),
              node_basename: Keyword.get(config, :node_basename, "hub")
            ]
          ]
        ]

      "epmd" ->
        hosts =
          config
          |> Keyword.get(:epmd_hosts, "hub1@127.0.0.1,hub2@127.0.0.1")
          |> parse_epmd_hosts()

        [
          hub: [
            strategy: Cluster.Strategy.Epmd,
            config: [hosts: hosts]
          ]
        ]

      unknown ->
        require Logger
        Logger.warning("[Hub.Cluster] Unknown strategy '#{unknown}', running standalone")
        []
    end
  end

  @doc "Returns the current cluster strategy name."
  def strategy do
    config = Application.get_env(:hub, __MODULE__, [])
    Keyword.get(config, :strategy, "none")
  end

  @doc "Returns the region tag for this node."
  def region do
    config = Application.get_env(:hub, __MODULE__, [])
    Keyword.get(config, :region, "local")
  end

  @doc "Returns true if clustering is enabled (strategy != none)."
  def enabled? do
    strategy() != "none"
  end

  @doc "Returns all connected BEAM nodes (excluding self)."
  def connected_nodes do
    Node.list()
  end

  @doc "Returns all cluster members including self."
  def all_nodes do
    [Node.self() | Node.list()]
  end

  # ── Private ───────────────────────────────────────────────

  defp parse_epmd_hosts(hosts) when is_binary(hosts) do
    hosts
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.to_atom/1)
  end

  defp parse_epmd_hosts(hosts) when is_list(hosts), do: hosts
end
