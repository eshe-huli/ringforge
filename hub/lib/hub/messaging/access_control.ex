defmodule Hub.Messaging.AccessControl do
  @moduledoc """
  Determines whether agent A can message agent B based on:
  - Role hierarchy tiers
  - Squad membership
  - Fleet-level rules

  Role Tiers:
    Tier 0 — fleet-admin: unrestricted
    Tier 1 — strategic: tech-lead, product-manager, consultant → cross-squad, fleet broadcast
    Tier 2 — tactical: squad-leader, devops → own squad + other leaders + escalate up
    Tier 3 — operational: backend-dev, frontend-dev, qa-engineer, designer, etc. → own squad only
    Tier 4 — restricted: unroled or tier-3 context agents → own squad, structured format only
  """

  import Ecto.Query
  alias Hub.Repo
  alias Hub.Auth.Agent
  alias Hub.Schemas.RoleTemplate

  require Logger

  # ── Tier 1: Strategic roles ────────────────────────────────
  @tier1_slugs ~w(tech-lead product-manager consultant)

  # ── Tier 2: Tactical roles ────────────────────────────────
  @tier2_slugs ~w(squad-leader devops)

  # ── Tier 3: Operational roles ──────────────────────────────
  @tier3_slugs ~w(
    backend-dev frontend-dev fullstack-dev qa-engineer designer
    data-engineer mobile-dev marketer technical-writer security-expert
  )

  # ── Role Tier ──────────────────────────────────────────────

  @doc """
  Returns the numeric tier (0-4) for a given role slug.

  - `nil` with fleet admin → 0
  - Strategic slugs → 1
  - Tactical slugs → 2
  - Operational slugs → 3
  - Unroled / weak context → 4
  """
  @spec role_tier(String.t() | nil) :: 0 | 1 | 2 | 3 | 4
  def role_tier(slug) when slug in @tier1_slugs, do: 1
  def role_tier(slug) when slug in @tier2_slugs, do: 2
  def role_tier(slug) when slug in @tier3_slugs, do: 3
  def role_tier(nil), do: 4
  # Unknown slugs default to tier 3 (operational)
  def role_tier(_unknown), do: 3

  @doc """
  Resolves the effective tier for an agent struct (with preloaded role_template).

  Fleet admins (first agent in fleet or metadata-flagged) get tier 0.
  Agents with no role and context_tier == "tier3" get tier 4.
  """
  @spec agent_tier(Agent.t()) :: 0 | 1 | 2 | 3 | 4
  def agent_tier(%Agent{} = agent) do
    slug = role_slug(agent)

    cond do
      fleet_admin?(agent) -> 0
      slug != nil -> role_tier(slug)
      agent.context_tier == "tier3" -> 4
      true -> 4
    end
  end

  # ── Can DM? ────────────────────────────────────────────────

  @doc """
  Checks whether `sender` can send a direct message to `target` within `fleet_id`.

  Accepts optional `rules` (from BusinessRules) — defaults to `nil` (use built-in rules).

  Returns:
  - `:ok` — allowed
  - `{:denied, reason, suggestion_map}` — not allowed, with actionable feedback
  """
  @spec can_dm?(Agent.t(), Agent.t(), String.t(), map() | nil) ::
          :ok | {:denied, String.t(), map()}
  def can_dm?(%Agent{} = sender, %Agent{} = target, _fleet_id, _rules \\ nil) do
    sender_tier = agent_tier(sender)
    target_tier = agent_tier(target)
    same_squad = same_squad?(sender, target)

    cond do
      # Same squad → always allowed
      same_squad ->
        :ok

      # Tier 0 → unrestricted
      sender_tier == 0 ->
        :ok

      # Tier 1 → can message anyone in fleet
      sender_tier == 1 ->
        :ok

      # Tier 2 → own squad + other tier 0-2 agents + escalations
      sender_tier == 2 and target_tier <= 2 ->
        :ok

      sender_tier == 2 ->
        squad_leader = find_squad_leader(sender)

        {:denied, "Tier 2 agents can only cross-squad message other leaders (tier 0-2)",
         %{
           suggestion: "Send to your squad leader who can relay to operational agents in other squads",
           alternative: "Use message:escalate to formally escalate",
           your_squad_leader: squad_leader_id(squad_leader)
         }}

      # Tier 3 → own squad only, cross-squad denied
      sender_tier == 3 ->
        squad_leader = find_squad_leader(sender)

        {:denied, "Cross-squad messaging requires Tier 1+ role",
         %{
           suggestion: "Send to your squad leader who can relay it",
           alternative: "Use message:escalate to formally escalate",
           your_squad_leader: squad_leader_id(squad_leader)
         }}

      # Tier 4 → own squad only, structured format
      sender_tier == 4 ->
        squad_leader = find_squad_leader(sender)

        {:denied, "Restricted agents can only message within their own squad",
         %{
           suggestion: "Send to your squad leader using structured format",
           alternative: "Use message:escalate to formally escalate",
           your_squad_leader: squad_leader_id(squad_leader),
           required_format: :structured
         }}

      # No squad assigned → can only message tier 1-2
      is_nil(sender.squad_id) and target_tier <= 2 ->
        :ok

      is_nil(sender.squad_id) ->
        {:denied, "Unassigned agents can only message tier 1-2 agents (leaders)",
         %{
           suggestion: "Request squad assignment from a fleet admin or tech-lead",
           alternative: "Use message:escalate to reach the right person"
         }}

      true ->
        {:denied, "Message not permitted by access control rules", %{}}
    end
  end

  # ── Can Broadcast? ─────────────────────────────────────────

  @doc """
  Checks whether `sender` can broadcast to `scope` (e.g., :fleet, :squad, {:squad, squad_id}).

  Returns `:ok` or `{:denied, reason}`.
  """
  @spec can_broadcast?(Agent.t(), atom() | tuple(), map() | nil) ::
          :ok | {:denied, String.t()}
  def can_broadcast?(%Agent{} = sender, scope, _rules \\ nil) do
    sender_tier = agent_tier(sender)

    case {sender_tier, scope} do
      # Tier 0-1 → fleet-wide broadcast allowed
      {tier, :fleet} when tier <= 1 ->
        :ok

      # Tier 2 → own squad broadcast only
      {2, :squad} ->
        :ok

      {2, {:squad, squad_id}} when squad_id == sender.squad_id ->
        :ok

      {2, :fleet} ->
        {:denied, "Fleet-wide broadcast requires Tier 1+ role (strategic or admin)"}

      # Tier 3 → own squad only
      {3, :squad} ->
        :ok

      {3, {:squad, squad_id}} when squad_id == sender.squad_id ->
        :ok

      {3, _} ->
        {:denied, "Operational agents can only broadcast to their own squad"}

      # Tier 4 → no broadcast at all
      {4, _} ->
        {:denied, "Restricted agents cannot broadcast messages"}

      _ ->
        {:denied, "Broadcast not permitted for this scope and tier"}
    end
  end

  # ── Can Escalate? ──────────────────────────────────────────

  @doc """
  Checks whether `sender` can escalate to `target_role` slug.

  Agents can always escalate upward (to higher tiers). Lateral and downward
  escalation is denied.

  Returns `:ok` or `{:denied, reason}`.
  """
  @spec can_escalate?(Agent.t(), String.t()) :: :ok | {:denied, String.t()}
  def can_escalate?(%Agent{} = sender, target_role_slug) do
    sender_tier = agent_tier(sender)
    target_tier = role_tier(target_role_slug)

    cond do
      # Can always escalate upward
      target_tier < sender_tier ->
        :ok

      # Tier 0 can escalate anywhere (they can do anything)
      sender_tier == 0 ->
        :ok

      # Same tier escalation — allowed (e.g., squad-leader → squad-leader)
      target_tier == sender_tier ->
        :ok

      true ->
        {:denied,
         "Cannot escalate to tier #{target_tier} (#{target_role_slug}) — " <>
           "your tier is #{sender_tier}, escalations go upward only"}
    end
  end

  # ── Communication Reach ────────────────────────────────────

  @doc """
  Returns a list of agent_ids that `agent` can directly message,
  based on their tier and squad membership.

  This is an expensive query — use sparingly (e.g., for UI display of
  available contacts, not per-message checks).
  """
  @spec communication_reach(Agent.t()) :: [String.t()]
  def communication_reach(%Agent{} = agent) do
    tier = agent_tier(agent)

    case tier do
      0 ->
        # Fleet admin: everyone in fleet
        fleet_agent_ids(agent.fleet_id)

      1 ->
        # Strategic: everyone in fleet
        fleet_agent_ids(agent.fleet_id)

      2 ->
        # Tactical: own squad + tier 0-2 agents in fleet
        own_squad = squad_agent_ids(agent.squad_id)
        leaders = fleet_agents_by_max_tier(agent.fleet_id, 2)
        Enum.uniq(own_squad ++ leaders)

      3 ->
        # Operational: own squad only
        squad_agent_ids(agent.squad_id)

      4 ->
        # Restricted: own squad only
        squad_agent_ids(agent.squad_id)

      _ ->
        []
    end
  end

  # ── Private Helpers ────────────────────────────────────────

  defp role_slug(%Agent{} = agent) do
    case agent.role_template do
      %RoleTemplate{slug: slug} -> slug
      %Ecto.Association.NotLoaded{} ->
        # Role wasn't preloaded — try loading it
        case Repo.preload(agent, :role_template) do
          %{role_template: %RoleTemplate{slug: slug}} -> slug
          _ -> nil
        end
      _ -> nil
    end
  end

  defp fleet_admin?(%Agent{} = agent) do
    # Check metadata flag first (explicit admin designation)
    admin_flag = get_in(agent.metadata || %{}, ["fleet_admin"])
    if admin_flag == true, do: true, else: false
  end

  defp same_squad?(%Agent{squad_id: nil}, _target), do: false
  defp same_squad?(_sender, %Agent{squad_id: nil}), do: false
  defp same_squad?(%Agent{squad_id: s}, %Agent{squad_id: t}), do: s == t

  defp find_squad_leader(%Agent{squad_id: nil}), do: nil

  defp find_squad_leader(%Agent{squad_id: squad_id}) do
    # Find agent in the same squad with role_template slug "squad-leader"
    from(a in Agent,
      join: r in RoleTemplate,
      on: a.role_template_id == r.id,
      where: a.squad_id == ^squad_id and r.slug == "squad-leader",
      limit: 1
    )
    |> Repo.one()
  end

  defp squad_leader_id(nil), do: nil
  defp squad_leader_id(%Agent{agent_id: id}), do: id

  defp fleet_agent_ids(nil), do: []

  defp fleet_agent_ids(fleet_id) do
    from(a in Agent,
      where: a.fleet_id == ^fleet_id,
      select: a.agent_id
    )
    |> Repo.all()
  end

  defp squad_agent_ids(nil), do: []

  defp squad_agent_ids(squad_id) do
    from(a in Agent,
      where: a.squad_id == ^squad_id,
      select: a.agent_id
    )
    |> Repo.all()
  end

  defp fleet_agents_by_max_tier(fleet_id, max_tier) do
    # Get all agents in fleet that have tier <= max_tier
    # We need to check role_template slugs + admin flag
    tier1_and_2_slugs = @tier1_slugs ++ @tier2_slugs

    # Agents with strategic/tactical roles
    roled =
      from(a in Agent,
        join: r in RoleTemplate,
        on: a.role_template_id == r.id,
        where: a.fleet_id == ^fleet_id and r.slug in ^tier1_and_2_slugs,
        select: a.agent_id
      )
      |> Repo.all()

    # Fleet admins (tier 0) — check metadata flag
    admins =
      if max_tier >= 0 do
        from(a in Agent,
          where:
            a.fleet_id == ^fleet_id and
              fragment("(?->>'fleet_admin')::boolean = true", a.metadata),
          select: a.agent_id
        )
        |> Repo.all()
      else
        []
      end

    Enum.uniq(roled ++ admins)
  end
end
