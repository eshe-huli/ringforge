defmodule Hub.FleetController do
  @moduledoc """
  Admin REST controller for fleet management.

  All actions are scoped to the authenticated admin's tenant.
  """

  use Phoenix.Controller, formats: [:json]

  import Ecto.Query

  alias Hub.Repo
  alias Hub.Auth.Fleet
  alias Hub.FleetPresence

  @doc "GET /api/v1/fleets — List fleets for tenant."
  def index(conn, _params) do
    tenant_id = conn.assigns.tenant_id

    fleets =
      from(f in Fleet, where: f.tenant_id == ^tenant_id, order_by: [asc: f.inserted_at])
      |> Repo.all()
      |> Enum.map(&fleet_json/1)

    json(conn, %{fleets: fleets, count: length(fleets)})
  end

  @doc "POST /api/v1/fleets — Create a fleet."
  def create(conn, params) do
    tenant_id = conn.assigns.tenant_id
    name = Map.get(params, "name")

    if is_nil(name) or name == "" do
      conn |> put_status(400) |> json(%{error: "validation_failed", message: "name is required"})
    else
      # Check fleet quota
      case Hub.Quota.increment(tenant_id, :fleets) do
        {:ok, _count} ->
          attrs = %{name: name, tenant_id: tenant_id}

          case %Fleet{} |> Fleet.changeset(attrs) |> Repo.insert() do
            {:ok, fleet} ->
              conn |> put_status(201) |> json(fleet_json(fleet))

            {:error, changeset} ->
              # Roll back quota increment on insert failure
              Hub.Quota.decrement(tenant_id, :fleets)

              conn
              |> put_status(400)
              |> json(%{error: "validation_failed", details: format_errors(changeset)})
          end

        {:error, :quota_exceeded} ->
          conn
          |> put_status(403)
          |> json(%{error: "quota_exceeded", resource: "fleets", message: "Fleet limit reached for your plan"})
      end
    end
  end

  @doc "GET /api/v1/fleets/:id — Get fleet details."
  def show(conn, %{"id" => id}) do
    tenant_id = conn.assigns.tenant_id

    case Repo.get(Fleet, id) do
      %Fleet{tenant_id: ^tenant_id} = fleet ->
        # Count connected agents
        connected =
          FleetPresence.list("fleet:#{fleet.id}")
          |> map_size()

        json(conn, fleet_json(fleet) |> Map.put(:connected_agents, connected))

      %Fleet{} ->
        conn |> put_status(403) |> json(%{error: "forbidden", message: "Access denied"})

      nil ->
        conn |> put_status(404) |> json(%{error: "not_found", message: "Fleet not found"})
    end
  end

  @doc "DELETE /api/v1/fleets/:id — Delete fleet (only if no connected agents)."
  def delete(conn, %{"id" => id}) do
    tenant_id = conn.assigns.tenant_id

    case Repo.get(Fleet, id) do
      %Fleet{tenant_id: ^tenant_id} = fleet ->
        connected =
          FleetPresence.list("fleet:#{fleet.id}")
          |> map_size()

        if connected > 0 do
          conn
          |> put_status(409)
          |> json(%{error: "conflict", message: "Cannot delete fleet with #{connected} connected agent(s)"})
        else
          case Repo.delete(fleet) do
            {:ok, _} ->
              Hub.Quota.decrement(tenant_id, :fleets)
              conn |> put_status(200) |> json(%{deleted: true, id: id})

            {:error, _} ->
              conn |> put_status(500) |> json(%{error: "delete_failed"})
          end
        end

      %Fleet{} ->
        conn |> put_status(403) |> json(%{error: "forbidden", message: "Access denied"})

      nil ->
        conn |> put_status(404) |> json(%{error: "not_found", message: "Fleet not found"})
    end
  end

  # ── Helpers ────────────────────────────────────────────────

  defp fleet_json(fleet) do
    %{
      id: fleet.id,
      name: fleet.name,
      tenant_id: fleet.tenant_id,
      inserted_at: fleet.inserted_at,
      updated_at: fleet.updated_at
    }
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
