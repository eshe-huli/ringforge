defmodule Hub.TaskRouter do
  @moduledoc """
  Capability-based task routing for the Ringforge fleet.

  Matches task requirements to online agents' declared capabilities.
  Considers agent state (prefer online over busy, never assign to away/offline),
  load balancing (prefer lower load), and region affinity (prefer same-region
  agents for lower latency).

  ## Routing Algorithm

  1. Get all tracked agents from FleetPresence for the fleet
  2. Filter by capabilities (agent must have ALL required capabilities)
  3. Filter by state (only "online", or "busy" with load < 0.8)
  4. Sort by: state priority, region affinity, then load (lowest first)
  5. Return `{:ok, best_agent_id}` or `{:error, :no_capable_agent}`
  """

  alias Hub.FleetPresence

  @doc """
  Route a task to the best available agent in a fleet.

  Returns `{:ok, agent_id}` or `{:error, :no_capable_agent}`.
  """
  def route(%Hub.Task{} = task, fleet_id) do
    required = task.capabilities_required || []

    candidates =
      FleetPresence.list("fleet:#{fleet_id}")
      |> Enum.flat_map(fn {agent_id, %{metas: metas}} ->
        Enum.map(metas, fn meta -> {agent_id, meta} end)
      end)
      |> Enum.filter(fn {_agent_id, meta} ->
        capabilities_match?(meta, required) and state_eligible?(meta)
      end)
      |> Enum.sort_by(fn {_agent_id, meta} ->
        {
          state_priority(meta[:state]),
          region_score(meta),
          meta[:load] || 0.0
        }
      end)

    case candidates do
      [{best_agent_id, _meta} | _rest] -> {:ok, best_agent_id}
      [] -> {:error, :no_capable_agent}
    end
  end

  # ── Private ───────────────────────────────────────────────

  # Agent must have ALL required capabilities.
  # If no capabilities are required, any agent matches.
  defp capabilities_match?(_meta, []), do: true

  defp capabilities_match?(meta, required) do
    agent_caps = MapSet.new(meta[:capabilities] || [])
    required_set = MapSet.new(required)
    MapSet.subset?(required_set, agent_caps)
  end

  # Only route to agents that are online or busy with low load.
  defp state_eligible?(meta) do
    state = meta[:state]
    load = meta[:load] || 0.0

    case state do
      "online" -> true
      "busy" -> load < 0.8
      _ -> false
    end
  end

  # Online agents preferred over busy.
  defp state_priority("online"), do: 0
  defp state_priority("busy"), do: 1
  defp state_priority(_), do: 99

  # Region affinity: same-region agents get a lower (better) score.
  # Returns 0.0 for same region, 1.0 for different region.
  defp region_score(meta) do
    agent_region = meta[:region] || meta[:node_region] || "local"
    Hub.Region.affinity_score(agent_region) + 0.5
  end
end
