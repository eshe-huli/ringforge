defmodule Hub.Socket do
  @moduledoc """
  WebSocket transport for Ringforge agents.

  Supports two connection modes:
  - **Registration**: `%{"api_key" => key, "agent" => %{...}}` — validates key,
    registers new agent, assigns tenant/fleet/agent to socket.
  - **Reconnect**: `%{"agent_id" => id}` — looks up existing agent,
    assigns tenant/fleet/agent to socket (challenge-response happens in channel).
  """
  use Phoenix.Socket
  require Logger

  channel "keyring:*", Hub.KeyringChannel
  channel "fleet:*", Hub.FleetChannel

  @impl true
  def connect(%{"api_key" => raw_key, "agent" => agent_info}, socket, _connect_info) do
    with {:ok, api_key} <- Hub.Auth.validate_api_key(raw_key),
         agent_params <- normalize_agent_params(agent_info),
         {:ok, agent} <- Hub.Auth.register_agent(api_key, agent_params) do
      Logger.info("Agent registered: #{agent.agent_id} (tenant=#{agent.tenant_id})")

      Hub.Telemetry.execute([:hub, :auth, :success], %{count: 1}, %{method: "api_key"})

      socket =
        socket
        |> assign(:tenant_id, agent.tenant_id)
        |> assign(:fleet_id, agent.fleet_id)
        |> assign(:agent_id, agent.agent_id)
        |> assign(:agent_db_id, agent.id)
        |> assign(:auth_mode, :registration)

      {:ok, socket}
    else
      {:error, reason} ->
        Hub.Telemetry.execute([:hub, :auth, :failure], %{count: 1}, %{method: "api_key"})
        Logger.warning("Socket auth failed (registration): #{inspect(reason)}")
        :error
    end
  end

  def connect(%{"agent_id" => agent_id, "api_key" => raw_key}, socket, _connect_info) do
    # Reconnect requires both agent_id AND a valid API key for the same tenant
    with {:ok, api_key} <- Hub.Auth.validate_api_key(raw_key),
         {:ok, agent} <- Hub.Auth.find_agent(agent_id),
         true <- agent.tenant_id == api_key.tenant_id do
      Hub.Auth.touch_agent(agent)
      Hub.Telemetry.execute([:hub, :auth, :success], %{count: 1}, %{method: "api_key"})
      Logger.info("Agent reconnected (key-verified): #{agent.agent_id}")

      socket =
        socket
        |> assign(:tenant_id, agent.tenant_id)
        |> assign(:fleet_id, agent.fleet_id)
        |> assign(:agent_id, agent.agent_id)
        |> assign(:agent_db_id, agent.id)
        |> assign(:auth_mode, :reconnect)

      {:ok, socket}
    else
      false ->
        Hub.Telemetry.execute([:hub, :auth, :failure], %{count: 1}, %{method: "api_key"})
        Logger.warning("Socket auth failed (reconnect): tenant mismatch for #{agent_id}")
        :error

      {:error, reason} ->
        Hub.Telemetry.execute([:hub, :auth, :failure], %{count: 1}, %{method: "api_key"})
        Logger.warning("Socket auth failed (reconnect): #{inspect(reason)} for #{agent_id}")
        :error
    end
  end

  def connect(%{"agent_id" => agent_id, "challenge_response" => sig}, socket, _connect_info) do
    # Reconnect via Ed25519 challenge-response.
    #
    # Flow:
    # 1. Agent POSTs to /api/auth/challenge with {agent_id} → gets {challenge}
    # 2. Agent signs challenge with Ed25519 private key
    # 3. Agent connects here with {agent_id, challenge_response: signature_b64}
    #
    # Hub looks up the pending challenge from ChallengeStore, verifies the
    # signature against the agent's stored public key, and authenticates.
    with {:ok, agent} <- Hub.Auth.find_agent(agent_id),
         {:ok, challenge} <- fetch_pending_challenge(agent_id),
         :ok <- verify_challenge_signature(agent, challenge, sig) do
      # Challenge consumed (deleted from store) on successful verify
      Hub.ChallengeStore.revoke(agent_id)
      Hub.Auth.touch_agent(agent)
      Hub.Telemetry.execute([:hub, :auth, :success], %{count: 1}, %{method: "ed25519"})
      Logger.info("Agent reconnected (challenge-verified): #{agent.agent_id}")

      socket =
        socket
        |> assign(:tenant_id, agent.tenant_id)
        |> assign(:fleet_id, agent.fleet_id)
        |> assign(:agent_id, agent.agent_id)
        |> assign(:agent_db_id, agent.id)
        |> assign(:auth_mode, :challenge)

      {:ok, socket}
    else
      {:error, reason} ->
        Hub.Telemetry.execute([:hub, :auth, :failure], %{count: 1}, %{method: "ed25519"})
        Logger.warning("Socket auth failed (challenge): #{inspect(reason)} for #{agent_id}")
        :error
    end
  end

  def connect(%{"agent_id" => _agent_id}, _socket, _connect_info) do
    # Reject bare agent_id reconnect without authentication
    Logger.warning("Socket auth failed: agent_id reconnect requires api_key or challenge_response")
    :error
  end

  # Fallback: reject unauthenticated connections
  def connect(_params, _socket, _connect_info) do
    Logger.warning("Socket auth failed: missing credentials")
    :error
  end

  @impl true
  def id(socket), do: "agent:#{socket.assigns[:agent_id]}"

  # --- Helpers ---

  defp normalize_agent_params(info) when is_map(info) do
    %{}
    |> maybe_put(:name, info["name"])
    |> maybe_put(:framework, info["framework"])
    |> maybe_put(:capabilities, info["capabilities"])
    |> maybe_put_public_key(info["public_key"])
  end

  defp normalize_agent_params(_), do: %{}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_public_key(map, nil), do: map

  defp maybe_put_public_key(map, pk_base64) when is_binary(pk_base64) do
    case Hub.Crypto.decode_public_key(pk_base64) do
      {:ok, pk_bytes} -> Map.put(map, :public_key, pk_bytes)
      _ -> map
    end
  end

  defp fetch_pending_challenge(agent_id) do
    case Hub.ChallengeStore.peek(agent_id) do
      {:ok, challenge} -> {:ok, challenge}
      :none -> {:error, :no_pending_challenge}
    end
  end

  defp verify_challenge_signature(%{public_key: pk}, challenge_b64, signature_b64)
       when is_binary(pk) and byte_size(pk) == 32 do
    Hub.Crypto.verify_signature_raw(pk, challenge_b64, signature_b64)
  end

  defp verify_challenge_signature(_, _, _), do: {:error, :no_public_key}
end
