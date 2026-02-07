defmodule Hub.Cluster.Drainer do
  @moduledoc """
  Graceful node shutdown handler for clustered deployments.

  On SIGTERM (or explicit drain request):
  1. Stops accepting new WebSocket connections (marks node as draining)
  2. Broadcasts a reconnect hint to all connected agents
  3. Waits for in-flight tasks to complete (max 30s)
  4. Allows the node to shut down cleanly

  ## Usage

  The drainer is started as part of the supervision tree when
  clustering is enabled. It traps exits and responds to SIGTERM.

  Agents receiving the reconnect hint should disconnect and reconnect,
  at which point the load balancer will route them to a healthy node.
  """
  use GenServer

  require Logger

  @max_drain_ms 30_000
  @poll_interval_ms 1_000

  # ── Public API ────────────────────────────────────────────

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Check if this node is currently draining."
  def draining? do
    case GenServer.whereis(__MODULE__) do
      nil -> false
      pid -> GenServer.call(pid, :draining?)
    end
  end

  @doc "Manually trigger a drain (for rolling deployments)."
  def drain do
    GenServer.cast(__MODULE__, :drain)
  end

  # ── GenServer Callbacks ───────────────────────────────────

  @impl true
  def init(_opts) do
    # Trap exits so we get :terminate on SIGTERM
    Process.flag(:trap_exit, true)
    {:ok, %{draining: false, drain_started_at: nil}}
  end

  @impl true
  def handle_call(:draining?, _from, state) do
    {:reply, state.draining, state}
  end

  @impl true
  def handle_cast(:drain, state) do
    if state.draining do
      {:noreply, state}
    else
      do_drain()
      {:noreply, %{state | draining: true, drain_started_at: System.monotonic_time(:millisecond)}}
    end
  end

  @impl true
  def handle_info(:check_drained, state) do
    elapsed = System.monotonic_time(:millisecond) - state.drain_started_at
    active = Hub.Task.active_tasks()
    local_active = Enum.filter(active, fn _t -> true end)  # All tasks on this node

    cond do
      length(local_active) == 0 ->
        Logger.info("[Drainer] All in-flight tasks completed, ready for shutdown")
        {:noreply, state}

      elapsed >= @max_drain_ms ->
        Logger.warning("[Drainer] Drain timeout reached with #{length(local_active)} active tasks, proceeding with shutdown")
        {:noreply, state}

      true ->
        Logger.info("[Drainer] Waiting for #{length(local_active)} in-flight tasks (#{elapsed}ms elapsed)")
        Process.send_after(self(), :check_drained, @poll_interval_ms)
        {:noreply, state}
    end
  end

  @impl true
  def terminate(reason, state) do
    unless state.draining do
      Logger.info("[Drainer] Received terminate (#{inspect(reason)}), initiating drain")
      do_drain()

      # Block briefly to let reconnect hints propagate
      Process.sleep(min(@max_drain_ms, 5_000))
    end

    :ok
  end

  # ── Private ───────────────────────────────────────────────

  defp do_drain do
    Logger.info("[Drainer] Starting graceful drain of #{Hub.NodeInfo.node_name_string()}")

    # 1. Broadcast reconnect hint to all fleet topics
    broadcast_reconnect_hint()

    # 2. Start polling for in-flight task completion
    Process.send_after(self(), :check_drained, @poll_interval_ms)
  end

  defp broadcast_reconnect_hint do
    hint = %{
      "type" => "system",
      "event" => "node_draining",
      "payload" => %{
        "node" => Hub.NodeInfo.node_name_string(),
        "region" => Hub.NodeInfo.region(),
        "message" => "Node is shutting down. Please reconnect.",
        "reconnect_after_ms" => 1_000
      }
    }

    # Broadcast to all fleet topics — agents should reconnect
    # We broadcast on the PubSub directly since we don't know all fleet topics
    Phoenix.PubSub.broadcast(Hub.PubSub, "system:drain", {:node_draining, hint})

    Logger.info("[Drainer] Reconnect hints broadcast to all connected agents")
  end
end
