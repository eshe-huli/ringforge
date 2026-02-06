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

  @impl true
  def connect(%{"api_key" => raw_key, "agent" => agent_info}, socket, _connect_info) do
    with {:ok, api_key} <- Hub.Auth.validate_api_key(raw_key),
         agent_params <- normalize_agent_params(agent_info),
         {:ok, agent} <- Hub.Auth.register_agent(api_key, agent_params) do
      Logger.info("Agent registered: #{agent.agent_id} (tenant=#{agent.tenant_id})")

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
        Logger.warning("Socket auth failed (registration): #{inspect(reason)}")
        :error
    end
  end

  def connect(%{"agent_id" => agent_id}, socket, _connect_info) do
    case Hub.Auth.find_agent(agent_id) do
      {:ok, agent} ->
        Hub.Auth.touch_agent(agent)
        Logger.info("Agent reconnected: #{agent.agent_id}")

        socket =
          socket
          |> assign(:tenant_id, agent.tenant_id)
          |> assign(:fleet_id, agent.fleet_id)
          |> assign(:agent_id, agent.agent_id)
          |> assign(:agent_db_id, agent.id)
          |> assign(:auth_mode, :reconnect)

        {:ok, socket}

      {:error, _} ->
        Logger.warning("Socket auth failed (reconnect): unknown agent_id #{agent_id}")
        :error
    end
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
    case Base.decode64(pk_base64) do
      {:ok, pk_bytes} when byte_size(pk_bytes) == 32 ->
        Map.put(map, :public_key, pk_bytes)

      _ ->
        map
    end
  end
end
