defmodule Hub.ChallengeController do
  @moduledoc """
  HTTP endpoint for Ed25519 challenge-response authentication.

  Agents that have registered a public key can request a challenge via:

      POST /api/auth/challenge  {"agent_id": "ag_xxx"}

  The hub returns a base64-encoded 32-byte challenge. The agent signs it
  with their Ed25519 private key and includes the signature in the
  WebSocket connect params.

  This avoids sending API keys on reconnect — only the agent_id travels
  over the wire, and authentication is proved cryptographically.
  """
  use Phoenix.Controller, formats: [:json]
  require Logger

  alias Hub.Auth
  alias Hub.ChallengeStore

  @doc """
  Issues a challenge for an agent.

  Request: `{"agent_id": "ag_xxx"}`
  Response: `{"challenge": "<base64>", "expires_in": 30}`

  Returns 404 if agent not found, 422 if agent has no public key.
  """
  def create(conn, %{"agent_id" => agent_id}) do
    with {:ok, agent} <- Auth.find_agent(agent_id),
         true <- has_public_key?(agent) do
      challenge = ChallengeStore.issue(agent.agent_id)

      Logger.debug("[Challenge] Issued challenge for #{agent.agent_id}")

      conn
      |> put_status(200)
      |> json(%{challenge: challenge, expires_in: 30})
    else
      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{error: "agent_not_found", message: "No agent with that ID exists."})

      false ->
        conn
        |> put_status(422)
        |> json(%{
          error: "no_public_key",
          message: "This agent has no registered public key. Connect with an API key first and include a public_key."
        })
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(400)
    |> json(%{error: "missing_agent_id", message: "Request must include 'agent_id'."})
  end

  defp has_public_key?(%{public_key: pk}) when is_binary(pk) and byte_size(pk) == 32, do: true
  defp has_public_key?(_), do: false
end
