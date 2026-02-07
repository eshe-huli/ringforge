defmodule Hub.TaskSupervisor do
  @moduledoc """
  Periodic task orchestrator for the Ringforge fleet.

  Runs a 1-second tick loop that:
  1. Routes pending tasks to available agents via TaskRouter
  2. Detects timed-out tasks (stuck in :assigned/:running past TTL)
  3. Cleans up old completed/failed tasks (> 5 min)
  4. Emits activity events for task lifecycle changes

  Started as part of the Application supervision tree.
  """
  use GenServer

  require Logger

  alias Hub.Task, as: TaskStore
  alias Hub.TaskRouter

  @tick_ms 1_000

  # ── Public API ────────────────────────────────────────────

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Notify the supervisor that a new task was submitted (triggers immediate routing)."
  def notify_new_task(fleet_id) do
    GenServer.cast(__MODULE__, {:new_task, fleet_id})
  end

  # ── GenServer Callbacks ───────────────────────────────────

  @impl true
  def init(_opts) do
    schedule_tick()
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:new_task, fleet_id}, state) do
    route_pending_for_fleet(fleet_id)
    {:noreply, state}
  end

  @impl true
  def handle_info(:tick, state) do
    try do
      process_tick()
    rescue
      e ->
        Logger.error("[TaskSupervisor] tick error: #{Exception.message(e)}")
    end

    schedule_tick()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Tick Logic ────────────────────────────────────────────

  defp process_tick do
    # 1. Find all fleets with pending tasks and route them
    route_all_pending()

    # 2. Check for timed-out tasks
    check_timeouts()

    # 3. Cleanup old terminal tasks
    TaskStore.cleanup_expired()
  end

  defp route_all_pending do
    # Get distinct fleet_ids from pending tasks
    TaskStore.all_tasks()
    |> Enum.filter(fn t -> t.status == :pending end)
    |> Enum.map(fn t -> t.fleet_id end)
    |> Enum.uniq()
    |> Enum.each(&route_pending_for_fleet/1)
  end

  defp route_pending_for_fleet(fleet_id) do
    pending = TaskStore.pending_for_fleet(fleet_id)

    Enum.each(pending, fn task ->
      case TaskRouter.route(task, fleet_id) do
        {:ok, agent_id} ->
          case TaskStore.assign(task.task_id, agent_id) do
            {:ok, updated_task} ->
              Logger.info("[TaskSupervisor] Assigned #{task.task_id} → #{agent_id}")
              push_task_assignment(updated_task, fleet_id)
              emit_activity(fleet_id, task.task_id, "task_started",
                "Task #{task.task_id} assigned to #{agent_id}", agent_id)

            {:error, reason} ->
              Logger.warning("[TaskSupervisor] Failed to assign #{task.task_id}: #{inspect(reason)}")
          end

        {:error, :no_capable_agent} ->
          # Leave as pending — will retry on next tick
          :ok
      end
    end)
  end

  defp check_timeouts do
    now = DateTime.utc_now()

    TaskStore.active_tasks()
    |> Enum.each(fn task ->
      age_ms = DateTime.diff(now, task.created_at, :millisecond)

      if age_ms > task.ttl_ms do
        Logger.warning("[TaskSupervisor] Task #{task.task_id} timed out (#{age_ms}ms > #{task.ttl_ms}ms)")
        TaskStore.timeout(task.task_id)

        # Notify requester of timeout
        push_task_timeout(task)
        emit_activity(task.fleet_id, task.task_id, "task_failed",
          "Task #{task.task_id} timed out", task.requester_id)
      end
    end)
  end

  # ── Push Notifications ────────────────────────────────────

  defp push_task_assignment(task, fleet_id) do
    # Push to the assigned agent via their direct PubSub topic
    msg = %{
      "type" => "task",
      "event" => "assigned",
      "payload" => %{
        "task_id" => task.task_id,
        "type" => task.type,
        "prompt" => task.prompt,
        "priority" => Atom.to_string(task.priority),
        "capabilities_required" => task.capabilities_required,
        "ttl_ms" => task.ttl_ms,
        "requester_id" => task.requester_id,
        "correlation_id" => task.correlation_id
      }
    }

    # Push to agent's direct topic (FleetChannel subscribes to this)
    Phoenix.PubSub.broadcast(
      Hub.PubSub,
      "fleet:#{fleet_id}:agent:#{task.assigned_to}",
      {:task_assigned, msg}
    )
  end

  defp push_task_timeout(task) do
    msg = %{
      "type" => "task",
      "event" => "timeout",
      "payload" => %{
        "task_id" => task.task_id,
        "status" => "timeout"
      }
    }

    Phoenix.PubSub.broadcast(
      Hub.PubSub,
      "fleet:#{task.fleet_id}:agent:#{task.requester_id}",
      {:task_result, msg}
    )
  end

  @doc false
  def push_task_result(task) do
    msg = %{
      "type" => "task",
      "event" => "result",
      "payload" => %{
        "task_id" => task.task_id,
        "result" => task.result,
        "error" => task.error,
        "status" => Atom.to_string(task.status),
        "correlation_id" => task.correlation_id
      }
    }

    Phoenix.PubSub.broadcast(
      Hub.PubSub,
      "fleet:#{task.fleet_id}:agent:#{task.requester_id}",
      {:task_result, msg}
    )
  end

  # ── Activity Emission ─────────────────────────────────────

  defp emit_activity(fleet_id, task_id, kind, description, agent_id) do
    msg = %{
      "type" => "activity",
      "event" => "broadcast",
      "payload" => %{
        "event_id" => "evt_task_" <> task_id,
        "from" => %{
          "agent_id" => "system",
          "name" => "Task System"
        },
        "kind" => kind,
        "description" => description,
        "tags" => ["task", task_id],
        "data" => %{"task_id" => task_id, "agent_id" => agent_id},
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
      }
    }

    Phoenix.PubSub.broadcast(Hub.PubSub, "fleet:#{fleet_id}", msg)
  end

  # ── Scheduling ────────────────────────────────────────────

  defp schedule_tick do
    Process.send_after(self(), :tick, @tick_ms)
  end
end
