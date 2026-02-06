defmodule Hub.TenantController do
  @moduledoc """
  Admin REST controller for tenant management.

  All actions are scoped to the authenticated admin's tenant.
  """

  use Phoenix.Controller, formats: [:json]

  alias Hub.Repo
  alias Hub.Auth.Tenant
  alias Hub.Quota

  @doc "GET /api/v1/tenants/:id — Get tenant details (own tenant only)."
  def show(conn, %{"id" => id}) do
    with :ok <- authorize_tenant(conn, id),
         %Tenant{} = tenant <- Repo.get(Tenant, id) do
      json(conn, %{
        id: tenant.id,
        name: tenant.name,
        plan: tenant.plan,
        inserted_at: tenant.inserted_at,
        updated_at: tenant.updated_at
      })
    else
      {:error, :forbidden} ->
        conn |> put_status(403) |> json(%{error: "forbidden", message: "Access denied"})

      nil ->
        conn |> put_status(404) |> json(%{error: "not_found", message: "Tenant not found"})
    end
  end

  @doc "PATCH /api/v1/tenants/:id — Update tenant name/plan."
  def update(conn, %{"id" => id} = params) do
    with :ok <- authorize_tenant(conn, id),
         %Tenant{} = tenant <- Repo.get(Tenant, id) do
      attrs =
        %{}
        |> maybe_put("name", params)
        |> maybe_put("plan", params)

      case Tenant.changeset(tenant, attrs) |> Repo.update() do
        {:ok, updated} ->
          # Update quota limits if plan changed
          if Map.has_key?(attrs, "plan") do
            Quota.set_plan_limits(updated.id, updated.plan)
          end

          json(conn, %{
            id: updated.id,
            name: updated.name,
            plan: updated.plan,
            updated_at: updated.updated_at
          })

        {:error, changeset} ->
          conn
          |> put_status(400)
          |> json(%{error: "validation_failed", details: format_errors(changeset)})
      end
    else
      {:error, :forbidden} ->
        conn |> put_status(403) |> json(%{error: "forbidden", message: "Access denied"})

      nil ->
        conn |> put_status(404) |> json(%{error: "not_found", message: "Tenant not found"})
    end
  end

  @doc "GET /api/v1/tenants/:id/usage — Current usage stats."
  def usage(conn, %{"id" => id}) do
    with :ok <- authorize_tenant(conn, id),
         %Tenant{} = tenant <- Repo.get(Tenant, id) do
      raw_usage = Quota.get_usage(id)

      usage =
        Map.new(raw_usage, fn {resource, %{used: used, limit: limit}} ->
          formatted =
            case limit do
              :unlimited -> %{used: used, limit: "unlimited"}
              n -> %{used: used, limit: n}
            end

          {resource, formatted}
        end)

      json(conn, %{
        tenant_id: id,
        plan: tenant.plan,
        usage: usage
      })
    else
      {:error, :forbidden} ->
        conn |> put_status(403) |> json(%{error: "forbidden", message: "Access denied"})

      nil ->
        conn |> put_status(404) |> json(%{error: "not_found", message: "Tenant not found"})
    end
  end

  # ── Helpers ────────────────────────────────────────────────

  defp authorize_tenant(conn, id) do
    if conn.assigns[:tenant_id] == id do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp maybe_put(map, key, params) do
    case Map.get(params, key) do
      nil -> map
      val -> Map.put(map, key, val)
    end
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
