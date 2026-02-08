defmodule Hub.Fleets do
  @moduledoc """
  Context for multi-fleet management.

  Tenants can create multiple fleets, each with a name and description.
  Agents can be assigned to fleets and optionally to squads within those fleets.
  Squads are groups with type "squad" (reusing the existing Groups schema).
  """

  import Ecto.Query
  alias Hub.Repo
  alias Hub.Auth.{Fleet, Agent}
  alias Hub.Groups
  alias Hub.Groups.Group

  # ── Fleet CRUD ──────────────────────────────────────────────

  @doc """
  Create a new fleet for a tenant.
  """
  def create_fleet(tenant_id, attrs) when is_map(attrs) do
    %Fleet{}
    |> Fleet.changeset(Map.merge(attrs, %{tenant_id: tenant_id}))
    |> Repo.insert()
  end

  @doc """
  List all fleets for a tenant with agent count and squad count.
  """
  def list_fleets(tenant_id) do
    from(f in Fleet,
      where: f.tenant_id == ^tenant_id,
      left_join: a in Agent, on: a.fleet_id == f.id,
      left_join: g in Group, on: g.fleet_id == f.id and g.type == "squad" and g.status == "active",
      group_by: f.id,
      select: %{
        id: f.id,
        name: f.name,
        description: f.description,
        tenant_id: f.tenant_id,
        inserted_at: f.inserted_at,
        updated_at: f.updated_at,
        agent_count: count(a.id, :distinct),
        squad_count: count(g.id, :distinct)
      },
      order_by: [asc: f.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Get a fleet by ID with its agents and squads preloaded.
  """
  def get_fleet(fleet_id) do
    case Repo.get(Fleet, fleet_id) do
      nil ->
        {:error, :not_found}

      fleet ->
        fleet = Repo.preload(fleet, [:agents])

        squads =
          from(g in Group,
            where: g.fleet_id == ^fleet_id and g.type == "squad" and g.status == "active",
            preload: [:members],
            order_by: [asc: g.name]
          )
          |> Repo.all()

        {:ok, fleet, squads}
    end
  end

  @doc """
  Get a fleet by ID (simple, no preloads). Returns the Fleet struct or nil.
  """
  def get_fleet!(fleet_id) do
    Repo.get(Fleet, fleet_id)
  end

  @doc """
  Update a fleet's name and/or description.
  """
  def update_fleet(fleet_id, attrs) do
    case Repo.get(Fleet, fleet_id) do
      nil ->
        {:error, :not_found}

      fleet ->
        fleet
        |> Fleet.changeset(attrs)
        |> Repo.update()
    end
  end

  @doc """
  Delete a fleet. Only allowed if:
  - Fleet has no agents assigned
  - Fleet is not the tenant's only fleet (preserve at least one)
  """
  def delete_fleet(fleet_id) do
    case Repo.get(Fleet, fleet_id) do
      nil ->
        {:error, :not_found}

      fleet ->
        agent_count =
          from(a in Agent, where: a.fleet_id == ^fleet_id, select: count())
          |> Repo.one()

        fleet_count =
          from(f in Fleet, where: f.tenant_id == ^fleet.tenant_id, select: count())
          |> Repo.one()

        cond do
          agent_count > 0 ->
            {:error, :has_agents}

          fleet_count <= 1 ->
            {:error, :last_fleet}

          true ->
            # Also dissolve any squads in this fleet
            from(g in Group, where: g.fleet_id == ^fleet_id and g.type == "squad")
            |> Repo.delete_all()

            Repo.delete(fleet)
        end
    end
  end

  # ── Agent ↔ Fleet Assignment ────────────────────────────────

  @doc """
  Move an agent to a different fleet. Clears any squad assignment since
  the squad belongs to the old fleet.
  """
  def assign_agent_to_fleet(agent_id, fleet_id) do
    case Repo.get_by(Agent, agent_id: agent_id) do
      nil ->
        {:error, :agent_not_found}

      agent ->
        case Repo.get(Fleet, fleet_id) do
          nil ->
            {:error, :fleet_not_found}

          fleet ->
            if fleet.tenant_id != agent.tenant_id do
              {:error, :cross_tenant}
            else
              agent
              |> Agent.changeset(%{fleet_id: fleet_id, squad_id: nil})
              |> Repo.update()
            end
        end
    end
  end

  # ── Agent ↔ Squad Assignment ────────────────────────────────

  @doc """
  Assign an agent to a squad. The squad must:
  - Exist and be active
  - Be of type "squad"
  - Belong to the same fleet as the agent
  """
  def assign_agent_to_squad(agent_id, squad_id) do
    case Repo.get_by(Agent, agent_id: agent_id) do
      nil ->
        {:error, :agent_not_found}

      agent ->
        case Repo.get(Group, squad_id) do
          nil ->
            {:error, :squad_not_found}

          squad ->
            cond do
              squad.type != "squad" ->
                {:error, :not_a_squad}

              squad.status != "active" ->
                {:error, :squad_dissolved}

              squad.fleet_id != agent.fleet_id ->
                {:error, :fleet_mismatch}

              true ->
                agent
                |> Agent.changeset(%{squad_id: squad.id})
                |> Repo.update()
            end
        end
    end
  end

  @doc """
  Remove an agent's squad assignment. The agent stays in its fleet.
  """
  def remove_agent_from_squad(agent_id) do
    case Repo.get_by(Agent, agent_id: agent_id) do
      nil ->
        {:error, :agent_not_found}

      agent ->
        agent
        |> Agent.changeset(%{squad_id: nil})
        |> Repo.update()
    end
  end

  # ── Squad CRUD (delegating to Groups) ──────────────────────

  @doc """
  Create a squad within a fleet.
  """
  def create_squad(fleet_id, attrs) do
    # Verify fleet exists
    case Repo.get(Fleet, fleet_id) do
      nil ->
        {:error, :fleet_not_found}

      _fleet ->
        Groups.create_group(
          Map.merge(attrs, %{fleet_id: fleet_id, type: "squad"})
        )
    end
  end

  @doc """
  List squads for a fleet.
  """
  def list_squads(fleet_id) do
    Groups.list_groups(fleet_id, type: "squad")
  end

  @doc """
  Get agents assigned to a specific squad.
  """
  def squad_agents(squad_id) do
    from(a in Agent,
      where: a.squad_id == ^squad_id,
      order_by: [asc: a.name]
    )
    |> Repo.all()
  end
end
