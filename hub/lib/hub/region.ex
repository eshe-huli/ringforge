defmodule Hub.Region do
  @moduledoc """
  Region-aware routing for multi-region deployments.

  Each Hub node has a region tag (from `HUB_REGION` env). When routing
  tasks to agents, same-region agents receive a scoring bonus to minimize
  cross-region latency.

  ## Region Format

  Regions follow cloud naming conventions: `"eu-central"`, `"us-east"`,
  `"ap-southeast"`, etc. The special region `"local"` indicates a
  development/single-node deployment with no region awareness.
  """

  alias Hub.FleetPresence

  @doc """
  Returns the current node's region.
  """
  def current do
    Hub.Cluster.region()
  end

  @doc """
  Checks if two regions are the same.
  Returns true if either region is "local" (development mode).
  """
  def same_region?(region_a, region_b) do
    region_a == "local" or region_b == "local" or region_a == region_b
  end

  @doc """
  Score a candidate agent for region affinity.

  Returns a float bonus (0.0 = no bonus, negative = bonus/preferred).
  This is designed to be added to a sort key where lower = better.

  - Same region: -0.5 (preferred)
  - Different region: 0.0 (neutral)
  - Local/dev: -0.5 (always preferred — no penalty in dev)
  """
  def affinity_score(agent_region) do
    current_region = current()

    if same_region?(current_region, agent_region) do
      -0.5
    else
      0.0
    end
  end

  @doc """
  Get region metadata for all connected agents in a fleet.

  Returns `[{agent_id, region}]` grouped by region.
  """
  def agents_by_region(fleet_id) do
    FleetPresence.list("fleet:#{fleet_id}")
    |> Enum.flat_map(fn {agent_id, %{metas: metas}} ->
      Enum.map(metas, fn meta ->
        {agent_id, meta[:region] || meta[:node_region] || "unknown"}
      end)
    end)
    |> Enum.group_by(fn {_agent_id, region} -> region end, fn {agent_id, _} -> agent_id end)
  end
end
