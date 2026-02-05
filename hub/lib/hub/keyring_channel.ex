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
    start_time = System.monotonic_time()
    node_id = Map.get(payload, "node_id", random_id())
    meta = Map.get(payload, "meta", %{})

    Hub.Presence.register(node_id, meta)
    socket = assign(socket, :node_id, node_id)
    Logger.info("[KeyringChannel] node joined: #{node_id}")

    # Telemetry + Events
    Hub.Telemetry.execute([:hub, :node, :join], %{
      system_time: System.system_time(),
      duration: System.monotonic_time() - start_time
    }, %{node_id: node_id})

    Hub.Telemetry.execute([:hub, :channel, :join], %{
      system_time: System.system_time()
    }, %{node_id: node_id, topic: "keyring:lobby"})

    Hub.Events.emit(:node_joined, %{node_id: node_id, meta: meta})

    {:ok, %{node_id: node_id}, socket}
  end

  def join("keyring:" <> _subtopic, _payload, _socket) do
    {:error, %{reason: "unknown subtopic"}}
  end

  # ── sync:push — edge pushes data to hub ────────────────────

  @impl true
  def handle_in("sync:push", %{"key" => key, "data" => data}, socket) do
    start_time = System.monotonic_time()
    node_id = socket.assigns.node_id
    Logger.debug("[KeyringChannel] sync:push from #{node_id}, key=#{key}")

    # Broadcast to all other nodes on this topic
    broadcast_from!(socket, "sync:push", %{
      "key" => key,
      "data" => data,
      "from" => node_id
    })

    duration = System.monotonic_time() - start_time
    payload_size = estimate_size(data)

    Hub.Telemetry.execute([:hub, :sync, :push], %{
      system_time: System.system_time(),
      duration: duration,
      payload_size: payload_size
    }, %{node_id: node_id})

    Hub.Events.emit(:sync_push, %{node_id: node_id, key: key, size: payload_size})

    {:reply, {:ok, %{status: "accepted"}}, socket}
  end

  # ── sync:pull — edge requests data from hub ────────────────

  def handle_in("sync:pull", %{"key" => key}, socket) do
    start_time = System.monotonic_time()
    node_id = socket.assigns.node_id
    Logger.debug("[KeyringChannel] sync:pull from #{node_id}, key=#{key}")

    # Ask all peers for the key — they respond via sync:push
    broadcast_from!(socket, "sync:pull", %{
      "key" => key,
      "from" => node_id
    })

    duration = System.monotonic_time() - start_time

    Hub.Telemetry.execute([:hub, :sync, :pull], %{
      system_time: System.system_time(),
      duration: duration
    }, %{node_id: node_id})

    Hub.Events.emit(:sync_pull, %{node_id: node_id, key: key})

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

      Hub.Telemetry.execute([:hub, :node, :leave], %{
        system_time: System.system_time()
      }, %{node_id: node_id})

      Hub.Telemetry.execute([:hub, :channel, :leave], %{
        system_time: System.system_time()
      }, %{node_id: node_id, topic: "keyring:lobby"})

      Hub.Events.emit(:node_left, %{node_id: node_id})
    end

    :ok
  end

  # ── Helpers ─────────────────────────────────────────────────

  defp random_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end

  defp estimate_size(data) when is_binary(data), do: byte_size(data)
  defp estimate_size(data), do: data |> :erlang.term_to_binary() |> byte_size()
end
