defmodule Hub.Plugs.AdminAuth do
  @moduledoc """
  Plug that validates admin API keys for REST endpoints.

  Reads the `Authorization: Bearer rf_admin_...` header, validates the key
  via `Hub.Auth.validate_api_key/1`, and checks that the key type is "admin".
  Assigns `tenant_id` and `api_key` to the connection on success.

  Returns 401 if the key is missing or invalid, 403 if the key is not admin type.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with {:ok, raw_key} <- extract_bearer(conn),
         {:ok, api_key} <- Hub.Auth.validate_api_key(raw_key),
         :ok <- check_admin(api_key) do
      conn
      |> assign(:tenant_id, api_key.tenant_id)
      |> assign(:api_key, api_key)
    else
      {:error, :missing_auth} ->
        conn
        |> put_status(401)
        |> json(%{error: "missing_authorization", message: "Authorization header required"})
        |> halt()

      {:error, :invalid} ->
        conn
        |> put_status(401)
        |> json(%{error: "invalid_api_key", message: "API key is invalid or revoked"})
        |> halt()

      {:error, :not_admin} ->
        conn
        |> put_status(403)
        |> json(%{error: "forbidden", message: "Admin API key required"})
        |> halt()
    end
  end

  defp extract_bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, String.trim(token)}
      _ -> {:error, :missing_auth}
    end
  end

  defp check_admin(%{type: "admin"}), do: :ok
  defp check_admin(_), do: {:error, :not_admin}
end
