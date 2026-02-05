defmodule Hub.KeyringChannel do
  @moduledoc """
  Phoenix Channel for edge-agent coordination.

  Topic: "keyring:lobby"

  Events:
    join        — register node presence
    sync:push   — receive blob/doc data from edge agents
    sync:pull   — request blob/doc data
    presence:list — return connected nodes
  """
  use Phoenix.Channel

  require Logger

  @impl true
  def join("keyring:lobby", payload, socket) do
    node_id = Map.get(payload, "node_id", random_id())
    meta = Map.get(payload, "meta", %{})

    Hub.Presence.register(node_id, meta)
    socket = assign(socket, :node_id, node_id)
    Logger.info("[KeyringChannel] node joined: #{node_id}")

    {:ok, %{node_id: node_id}, socket}
  end

  def join("keyring:" <> _subtopic, _payload, _socket) do
    {:error, %{reason: "unknown subtopic"}}
  end

  # ── sync:push — edge pushes data to hub ────────────────────

  @impl true
  def handle_in("sync:push", %{"key" => key, "data" => data}, socket) do
    node_id = socket.assigns.node_id
    Logger.debug("[KeyringChannel] sync:push from #{node_id}, key=#{key}")

    # Broadcast to all other nodes on this topic
    broadcast_from!(socket, "sync:push", %{
      "key" => key,
      "data" => data,
      "from" => node_id
    })

    {:reply, {:ok, %{status: "accepted"}}, socket}
  end

  # ── sync:pull — edge requests data from hub ────────────────

  def handle_in("sync:pull", %{"key" => key}, socket) do
    node_id = socket.assigns.node_id
    Logger.debug("[KeyringChannel] sync:pull from #{node_id}, key=#{key}")

    # Ask all peers for the key — they respond via sync:push
    broadcast_from!(socket, "sync:pull", %{
      "key" => key,
      "from" => node_id
    })

    {:reply, {:ok, %{status: "requested"}}, socket}
  end

  # ── presence:list — return connected nodes ─────────────────

  def handle_in("presence:list", _payload, socket) do
    nodes = Hub.Presence.list()
    {:reply, {:ok, %{nodes: nodes}}, socket}
  end

  # ── Cleanup on disconnect ──────────────────────────────────

  @impl true
  def terminate(_reason, socket) do
    if node_id = socket.assigns[:node_id] do
      Hub.Presence.unregister(node_id)
      Logger.info("[KeyringChannel] node left: #{node_id}")
    end

    :ok
  end

  # ── Helpers ─────────────────────────────────────────────────

  defp random_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end
end
