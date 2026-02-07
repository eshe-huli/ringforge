defmodule Hub.KeyController do
  @moduledoc """
  Admin REST controller for API key management.

  Lists keys showing only prefix + type + created_at (never the raw key).
  New keys return the raw key exactly once at creation time.
  Deletion soft-revokes keys by setting `revoked_at`.
  """

  use Phoenix.Controller, formats: [:json]

  import Ecto.Query

  alias Hub.Repo
  alias Hub.Auth
  alias Hub.Auth.ApiKey

  @doc "GET /api/v1/keys — List API keys for tenant."
  def index(conn, _params) do
    tenant_id = conn.assigns.tenant_id

    keys =
      from(k in ApiKey,
        where: k.tenant_id == ^tenant_id and is_nil(k.revoked_at),
        order_by: [desc: k.inserted_at]
      )
      |> Repo.all()
      |> Enum.map(&key_json/1)

    json(conn, %{keys: keys, count: length(keys)})
  end

  @doc "POST /api/v1/keys — Generate a new API key. Returns the raw key ONCE."
  def create(conn, params) do
    tenant_id = conn.assigns.tenant_id
    type = Map.get(params, "type", "live")
    fleet_id = Map.get(params, "fleet_id")

    if type not in ["live", "test", "admin"] do
      conn
      |> put_status(400)
      |> json(%{error: "validation_failed", message: "type must be one of: live, test, admin"})
    else
      case Auth.generate_api_key(type, tenant_id, fleet_id) do
        {:ok, raw_key, api_key} ->
          conn
          |> put_status(201)
          |> json(%{
            id: api_key.id,
            key: raw_key,
            prefix: api_key.key_prefix,
            type: api_key.type,
            fleet_id: api_key.fleet_id,
            inserted_at: api_key.inserted_at,
            message: "Save this key — it will not be shown again"
          })

        {:error, changeset} ->
          conn
          |> put_status(400)
          |> json(%{error: "creation_failed", details: format_errors(changeset)})
      end
    end
  end

  @doc "DELETE /api/v1/keys/:id — Revoke a key (set revoked_at)."
  def delete(conn, %{"id" => id}) do
    tenant_id = conn.assigns.tenant_id

    case Repo.get(ApiKey, id) do
      %ApiKey{tenant_id: ^tenant_id} = key ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        case key |> ApiKey.changeset(%{revoked_at: now}) |> Repo.update() do
          {:ok, _} ->
            Hub.Audit.log("api_key.revoked", {"tenant", tenant_id}, {"api_key", id}, %{
              tenant_id: tenant_id,
              key_prefix: key.key_prefix
            })

            json(conn, %{revoked: true, id: id})

          {:error, _} ->
            conn |> put_status(500) |> json(%{error: "revoke_failed"})
        end

      %ApiKey{} ->
        conn |> put_status(403) |> json(%{error: "forbidden", message: "Access denied"})

      nil ->
        conn |> put_status(404) |> json(%{error: "not_found", message: "Key not found"})
    end
  end

  # ── Helpers ────────────────────────────────────────────────

  defp key_json(key) do
    %{
      id: key.id,
      prefix: key.key_prefix,
      type: key.type,
      fleet_id: key.fleet_id,
      inserted_at: key.inserted_at
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
