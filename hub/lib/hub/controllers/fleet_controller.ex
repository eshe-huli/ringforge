defmodule Hub.FleetController do
  @moduledoc """
  Admin REST controller for fleet management.

  All actions are scoped to the authenticated admin's tenant.
  Supports multi-fleet CRUD, agent assignment, and squad management.
  """

  use Phoenix.Controller, formats: [:json]

  alias Hub.Repo
  alias Hub.Auth.Fleet
  alias Hub.Fleets
  alias Hub.FleetPresence

  # ── Fleet CRUD ─────────────────────────────────────────────

  @doc "GET /api/v1/fleets — List fleets for tenant."
  def index(conn, _params) do
    tenant_id = conn.assigns.tenant_id
    fleets = Fleets.list_fleets(tenant_id)
    json(conn, %{fleets: fleets, count: length(fleets)})
  end

  @doc "POST /api/v1/fleets — Create a fleet."
  def create(conn, params) do
    tenant_id = conn.assigns.tenant_id
    name = Map.get(params, "name")

    if is_nil(name) or name == "" do
      conn |> put_status(400) |> json(%{error: "validation_failed", message: "name is required"})
    else
      attrs = %{name: name, description: Map.get(params, "description")}

      case Fleets.create_fleet(tenant_id, attrs) do
        {:ok, fleet} ->
          Hub.Audit.log("fleet.created", {"tenant", tenant_id}, {"fleet", fleet.id}, %{
            tenant_id: tenant_id,
            name: name
          })

          conn |> put_status(201) |> json(fleet_json(fleet))

        {:error, changeset} ->
          conn
          |> put_status(400)
          |> json(%{error: "validation_failed", details: format_errors(changeset)})
      end
    end
  end

  @doc "GET /api/v1/fleets/:id — Get fleet details with agents and squads."
  def show(conn, %{"id" => id}) do
    tenant_id = conn.assigns.tenant_id

    case Fleets.get_fleet(id) do
      {:ok, %Fleet{tenant_id: ^tenant_id} = fleet, squads} ->
        connected =
          FleetPresence.list("fleet:#{fleet.id}")
          |> map_size()

        agents =
          fleet.agents
          |> Enum.map(fn a ->
            %{
              agent_id: a.agent_id,
              name: a.name,
              fleet_id: a.fleet_id,
              squad_id: a.squad_id,
              framework: a.framework,
              capabilities: a.capabilities,
              last_seen_at: a.last_seen_at && DateTime.to_iso8601(a.last_seen_at)
            }
          end)

        squad_list =
          squads
          |> Enum.map(fn s ->
            squad_agents = Fleets.squad_agents(s.id)
            %{
              id: s.id,
              group_id: s.group_id,
              name: s.name,
              capabilities: s.capabilities,
              status: s.status,
              agent_count: length(squad_agents),
              agents: Enum.map(squad_agents, fn a -> %{agent_id: a.agent_id, name: a.name} end),
              member_count: length(s.members || [])
            }
          end)

        json(conn, %{
          id: fleet.id,
          name: fleet.name,
          description: fleet.description,
          tenant_id: fleet.tenant_id,
          connected_agents: connected,
          agents: agents,
          squads: squad_list,
          inserted_at: fleet.inserted_at,
          updated_at: fleet.updated_at
        })

      {:ok, %Fleet{}, _squads} ->
        conn |> put_status(403) |> json(%{error: "forbidden", message: "Access denied"})

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "not_found", message: "Fleet not found"})
    end
  end

  @doc "PUT /api/v1/fleets/:id — Update fleet name/description."
  def update(conn, %{"id" => id} = params) do
    tenant_id = conn.assigns.tenant_id

    case Repo.get(Fleet, id) do
      %Fleet{tenant_id: ^tenant_id} ->
        attrs =
          %{}
          |> maybe_put(:name, Map.get(params, "name"))
          |> maybe_put(:description, Map.get(params, "description"))

        case Fleets.update_fleet(id, attrs) do
          {:ok, fleet} ->
            Hub.Audit.log("fleet.updated", {"tenant", tenant_id}, {"fleet", fleet.id}, %{
              changes: Map.keys(attrs)
            })

            json(conn, fleet_json(fleet))

          {:error, :not_found} ->
            conn |> put_status(404) |> json(%{error: "not_found"})

          {:error, changeset} ->
            conn |> put_status(400) |> json(%{error: "validation_failed", details: format_errors(changeset)})
        end

      %Fleet{} ->
        conn |> put_status(403) |> json(%{error: "forbidden", message: "Access denied"})

      nil ->
        conn |> put_status(404) |> json(%{error: "not_found", message: "Fleet not found"})
    end
  end

  @doc "DELETE /api/v1/fleets/:id — Delete fleet."
  def delete(conn, %{"id" => id}) do
    tenant_id = conn.assigns.tenant_id

    case Repo.get(Fleet, id) do
      %Fleet{tenant_id: ^tenant_id} ->
        case Fleets.delete_fleet(id) do
          {:ok, _} ->
            Hub.Audit.log("fleet.deleted", {"tenant", tenant_id}, {"fleet", id}, %{})
            json(conn, %{deleted: true, id: id})

          {:error, :has_agents} ->
            conn |> put_status(409) |> json(%{error: "conflict", message: "Cannot delete fleet with agents assigned. Move agents first."})

          {:error, :last_fleet} ->
            conn |> put_status(409) |> json(%{error: "conflict", message: "Cannot delete the last fleet. Tenants must have at least one fleet."})

          {:error, :not_found} ->
            conn |> put_status(404) |> json(%{error: "not_found"})
        end

      %Fleet{} ->
        conn |> put_status(403) |> json(%{error: "forbidden", message: "Access denied"})

      nil ->
        conn |> put_status(404) |> json(%{error: "not_found", message: "Fleet not found"})
    end
  end

  # ── Agent ↔ Fleet Assignment ───────────────────────────────

  @doc "POST /api/v1/fleets/:fleet_id/agents/:agent_id — Assign agent to fleet."
  def assign_agent(conn, %{"fleet_id" => fleet_id, "agent_id" => agent_id}) do
    tenant_id = conn.assigns.tenant_id

    # Verify fleet belongs to tenant
    case Repo.get(Fleet, fleet_id) do
      %Fleet{tenant_id: ^tenant_id} ->
        case Fleets.assign_agent_to_fleet(agent_id, fleet_id) do
          {:ok, agent} ->
            json(conn, %{
              agent_id: agent.agent_id,
              fleet_id: agent.fleet_id,
              squad_id: agent.squad_id,
              message: "Agent assigned to fleet"
            })

          {:error, :agent_not_found} ->
            conn |> put_status(404) |> json(%{error: "not_found", message: "Agent not found"})

          {:error, :cross_tenant} ->
            conn |> put_status(403) |> json(%{error: "forbidden", message: "Cannot assign agent across tenants"})

          {:error, reason} ->
            conn |> put_status(400) |> json(%{error: "failed", message: inspect(reason)})
        end

      _ ->
        conn |> put_status(404) |> json(%{error: "not_found", message: "Fleet not found"})
    end
  end

  # ── Squad Management ───────────────────────────────────────

  @doc "POST /api/v1/fleets/:fleet_id/squads — Create squad in fleet."
  def create_squad(conn, %{"fleet_id" => fleet_id} = params) do
    tenant_id = conn.assigns.tenant_id

    case Repo.get(Fleet, fleet_id) do
      %Fleet{tenant_id: ^tenant_id} ->
        name = Map.get(params, "name")

        if is_nil(name) or name == "" do
          conn |> put_status(400) |> json(%{error: "validation_failed", message: "name is required"})
        else
          attrs = %{
            name: name,
            capabilities: Map.get(params, "capabilities", []),
            settings: Map.get(params, "settings", %{}),
            created_by: "admin"
          }

          case Fleets.create_squad(fleet_id, attrs) do
            {:ok, squad} ->
              conn |> put_status(201) |> json(%{
                id: squad.id,
                group_id: squad.group_id,
                name: squad.name,
                type: squad.type,
                fleet_id: squad.fleet_id,
                capabilities: squad.capabilities,
                status: squad.status
              })

            {:error, :fleet_not_found} ->
              conn |> put_status(404) |> json(%{error: "not_found", message: "Fleet not found"})

            {:error, changeset} ->
              conn |> put_status(400) |> json(%{error: "validation_failed", details: format_errors(changeset)})
          end
        end

      _ ->
        conn |> put_status(404) |> json(%{error: "not_found", message: "Fleet not found or access denied"})
    end
  end

  @doc "POST /api/v1/squads/:squad_id/agents/:agent_id — Assign agent to squad."
  def assign_agent_to_squad(conn, %{"squad_id" => squad_id, "agent_id" => agent_id}) do
    case Fleets.assign_agent_to_squad(agent_id, squad_id) do
      {:ok, agent} ->
        json(conn, %{
          agent_id: agent.agent_id,
          fleet_id: agent.fleet_id,
          squad_id: agent.squad_id,
          message: "Agent assigned to squad"
        })

      {:error, :agent_not_found} ->
        conn |> put_status(404) |> json(%{error: "not_found", message: "Agent not found"})

      {:error, :squad_not_found} ->
        conn |> put_status(404) |> json(%{error: "not_found", message: "Squad not found"})

      {:error, :not_a_squad} ->
        conn |> put_status(400) |> json(%{error: "invalid", message: "Target group is not a squad"})

      {:error, :squad_dissolved} ->
        conn |> put_status(400) |> json(%{error: "invalid", message: "Squad has been dissolved"})

      {:error, :fleet_mismatch} ->
        conn |> put_status(400) |> json(%{error: "fleet_mismatch", message: "Squad and agent must belong to the same fleet"})

      {:error, reason} ->
        conn |> put_status(400) |> json(%{error: "failed", message: inspect(reason)})
    end
  end

  @doc "DELETE /api/v1/squads/:squad_id/agents/:agent_id — Remove agent from squad."
  def remove_agent_from_squad(conn, %{"squad_id" => _squad_id, "agent_id" => agent_id}) do
    case Fleets.remove_agent_from_squad(agent_id) do
      {:ok, agent} ->
        json(conn, %{
          agent_id: agent.agent_id,
          fleet_id: agent.fleet_id,
          squad_id: nil,
          message: "Agent removed from squad"
        })

      {:error, :agent_not_found} ->
        conn |> put_status(404) |> json(%{error: "not_found", message: "Agent not found"})

      {:error, reason} ->
        conn |> put_status(400) |> json(%{error: "failed", message: inspect(reason)})
    end
  end

  # ── Helpers ────────────────────────────────────────────────

  defp fleet_json(fleet) do
    %{
      id: fleet.id,
      name: fleet.name,
      description: fleet.description,
      tenant_id: fleet.tenant_id,
      inserted_at: fleet.inserted_at,
      updated_at: fleet.updated_at
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
