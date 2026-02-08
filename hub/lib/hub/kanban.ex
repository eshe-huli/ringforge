defmodule Hub.Kanban do
  @moduledoc """
  AI-native kanban task management.

  Multi-level (fleet/squad/agent) task board optimized for AI consumption.
  Tasks flow through lanes: backlog → ready → in_progress → review → done

  This is the persistent counterpart to `Hub.Task` (ephemeral ETS-based).
  Kanban tasks have full lifecycle tracking, dependency management,
  smart assignment, and velocity analytics.
  """

  import Ecto.Query
  alias Hub.Repo
  alias Hub.Schemas.{KanbanTask, KanbanTaskHistory}
  alias Hub.FleetPresence

  require Logger

  # ── Valid lane transitions ──
  # backlog → ready
  # ready → in_progress
  # in_progress → review
  # in_progress → ready (deprioritized)
  # review → done
  # review → in_progress (rejected)
  # any → cancelled
  @valid_transitions %{
    "backlog" => ~w(ready cancelled),
    "ready" => ~w(in_progress cancelled),
    "in_progress" => ~w(review ready cancelled),
    "review" => ~w(done in_progress cancelled),
    "done" => ~w(cancelled),
    "cancelled" => ~w(backlog)
  }

  @priority_sort %{
    "critical" => 0,
    "high" => 1,
    "medium" => 2,
    "low" => 3
  }

  # ════════════════════════════════════════════════════════════
  # Task CRUD
  # ════════════════════════════════════════════════════════════

  @doc """
  Create a new kanban task. Auto-generates a sequential task_id (T-001).

  Returns `{:ok, task}` or `{:error, changeset}`.
  """
  def create_task(fleet_id, attrs) when is_map(attrs) do
    task_id = generate_task_id(fleet_id)

    full_attrs =
      attrs
      |> Map.put(:task_id, task_id)
      |> Map.put(:fleet_id, fleet_id)
      |> ensure_string_keys_to_atoms()

    changeset = KanbanTask.changeset(%KanbanTask{}, full_attrs)

    case Repo.insert(changeset) do
      {:ok, task} ->
        # Record initial history entry
        record_history(task.id, nil, task.lane, attrs[:created_by] || attrs["created_by"], "task created")
        {:ok, task}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc "Update a kanban task by task_id string."
  def update_task(task_id, attrs) when is_binary(task_id) and is_map(attrs) do
    case get_task(task_id) do
      {:ok, task} ->
        attrs = ensure_string_keys_to_atoms(attrs)

        task
        |> KanbanTask.changeset(attrs)
        |> Repo.update()

      {:error, _} = err ->
        err
    end
  end

  @doc "Soft-delete a task (move to cancelled lane)."
  def delete_task(task_id, agent_id \\ "system") do
    move_task(task_id, "cancelled", agent_id, "deleted")
  end

  @doc "Get a task by its human-readable task_id string (e.g. 'T-001')."
  def get_task(task_id) when is_binary(task_id) do
    case Repo.one(from t in KanbanTask, where: t.task_id == ^task_id) do
      nil -> {:error, :not_found}
      task -> {:ok, task}
    end
  end

  @doc "Get a task by its database UUID."
  def get_task_by_id(id) do
    case Repo.get(KanbanTask, id) do
      nil -> {:error, :not_found}
      task -> {:ok, task}
    end
  end

  # ════════════════════════════════════════════════════════════
  # Lane Management
  # ════════════════════════════════════════════════════════════

  @doc """
  Move a task between lanes. Validates transitions, records history.

  When moving to "done", automatically checks and unblocks dependents.
  Returns `{:ok, task}` or `{:error, reason}`.
  """
  def move_task(task_id, new_lane, agent_id, reason \\ nil) do
    with {:ok, task} <- get_task(task_id),
         :ok <- validate_transition(task.lane, new_lane) do
      now = DateTime.utc_now()

      move_attrs = %{lane: new_lane}
      move_attrs = if new_lane == "in_progress" and is_nil(task.started_at),
        do: Map.put(move_attrs, :started_at, now), else: move_attrs
      move_attrs = if new_lane == "done",
        do: Map.put(move_attrs, :completed_at, now), else: move_attrs
      # Clear blocked_by when moving out of in_progress (unblocked)
      move_attrs = if task.lane == "in_progress" and new_lane != "in_progress",
        do: Map.put(move_attrs, :blocked_by, []), else: move_attrs

      case task |> KanbanTask.move_changeset(move_attrs) |> Repo.update() do
        {:ok, updated_task} ->
          record_history(task.id, task.lane, new_lane, agent_id, reason)

          # When completing a task, unblock dependents + close linked threads
          if new_lane == "done" do
            unblock_dependents(task.task_id)

            # Close any threads linked to this task
            Task.start(fn ->
              Hub.Messaging.Threads.close_task_threads(task.task_id)
            end)
          end

          {:ok, updated_task}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc "Reorder tasks within a lane. Expects a list of `{task_id, position}` tuples."
  def reorder_tasks(fleet_id, lane, ordering) when is_list(ordering) do
    Repo.transaction(fn ->
      Enum.each(ordering, fn {task_id, position} ->
        from(t in KanbanTask,
          where: t.task_id == ^task_id and t.fleet_id == ^fleet_id and t.lane == ^lane
        )
        |> Repo.update_all(set: [position: position])
      end)
    end)
  end

  # ════════════════════════════════════════════════════════════
  # Board Views (AI-optimized)
  # ════════════════════════════════════════════════════════════

  @doc """
  Full fleet kanban board as a structured map.

  Returns `%{"backlog" => [tasks], "ready" => [tasks], ...}`.
  """
  def fleet_board(fleet_id) do
    tasks =
      from(t in KanbanTask,
        where: t.fleet_id == ^fleet_id and t.lane != "cancelled",
        order_by: [asc: :position, desc: :priority, asc: :inserted_at]
      )
      |> Repo.all()

    group_by_lane(tasks)
  end

  @doc "Squad-level board (only tasks scoped to or assigned within a squad)."
  def squad_board(squad_id) do
    tasks =
      from(t in KanbanTask,
        where: t.squad_id == ^squad_id and t.lane != "cancelled",
        order_by: [asc: :position, desc: :priority, asc: :inserted_at]
      )
      |> Repo.all()

    group_by_lane(tasks)
  end

  @doc """
  Personal task queue for an agent, ordered by priority.

  Includes tasks assigned to the agent + unassigned tasks in their squad.
  """
  def agent_queue(agent_id, fleet_id) do
    tasks =
      from(t in KanbanTask,
        where: t.fleet_id == ^fleet_id and t.assigned_to == ^agent_id and t.lane not in ["done", "cancelled"],
        order_by: [
          fragment("CASE ? WHEN 'in_progress' THEN 0 WHEN 'review' THEN 1 WHEN 'ready' THEN 2 WHEN 'backlog' THEN 3 ELSE 4 END", t.lane),
          fragment("CASE ? WHEN 'critical' THEN 0 WHEN 'high' THEN 1 WHEN 'medium' THEN 2 WHEN 'low' THEN 3 ELSE 4 END", t.priority),
          asc: t.position
        ]
      )
      |> Repo.all()

    tasks
  end

  @doc """
  What should this agent work on next?

  Priority logic:
  1. In-progress tasks assigned to agent (finish what you started)
  2. Ready tasks assigned to agent
  3. Ready unassigned tasks in agent's squad matching capabilities
  4. Ready unassigned fleet tasks matching capabilities
  """
  def next_task(agent_id, fleet_id) do
    # 1. In-progress assigned to agent
    case find_task(fleet_id, agent_id, "in_progress") do
      %KanbanTask{} = t -> {:ok, t}
      nil ->
        # 2. Ready assigned to agent
        case find_task(fleet_id, agent_id, "ready") do
          %KanbanTask{} = t -> {:ok, t}
          nil ->
            # 3-4. Ready unassigned tasks (squad then fleet)
            agent_caps = get_agent_capabilities(agent_id, fleet_id)
            squad_id = get_agent_squad_id(agent_id)

            case find_unassigned_task(fleet_id, squad_id, agent_caps) do
              %KanbanTask{} = t -> {:ok, t}
              nil -> {:ok, nil}
            end
        end
    end
  end

  # ════════════════════════════════════════════════════════════
  # Smart Assignment
  # ════════════════════════════════════════════════════════════

  @doc """
  Auto-assign a task to the best available agent.

  Scoring: capabilities match → lower workload → squad affinity → online status.
  Returns `{:ok, task}` or `{:error, reason}`.
  """
  def auto_assign(task_id, fleet_id) do
    with {:ok, task} <- get_task(task_id) do
      case suggest_assignee(task_id, fleet_id) do
        {:ok, nil} ->
          {:error, :no_capable_agent}

        {:ok, agent_id} ->
          now = DateTime.utc_now()
          assign_attrs = %{assigned_to: agent_id}
          assign_attrs = if task.lane in ["backlog", "ready"],
            do: Map.merge(assign_attrs, %{lane: "in_progress", started_at: now}),
            else: assign_attrs

          case task |> KanbanTask.assign_changeset(assign_attrs) |> Repo.update() do
            {:ok, updated} ->
              if assign_attrs[:lane] do
                record_history(task.id, task.lane, "in_progress", agent_id, "auto-assigned")
              end
              {:ok, updated}

            {:error, changeset} ->
              {:error, changeset}
          end

        {:error, _} = err ->
          err
      end
    end
  end

  @doc """
  Suggest the best agent for a task without actually assigning.

  Returns `{:ok, agent_id}` or `{:ok, nil}` if nobody qualifies.
  """
  def suggest_assignee(task_id, fleet_id) do
    with {:ok, task} <- get_task(task_id) do
      required_caps = task.requires_capabilities || []

      # Get all online agents in the fleet from presence
      candidates =
        FleetPresence.list("fleet:#{fleet_id}")
        |> Enum.flat_map(fn {agent_id, %{metas: metas}} ->
          Enum.map(metas, fn meta -> {agent_id, meta} end)
        end)
        |> Enum.filter(fn {_agent_id, meta} ->
          state = meta[:state]
          state in ["online", "busy"]
        end)
        |> Enum.filter(fn {_agent_id, meta} ->
          # Must have all required capabilities
          if required_caps == [] do
            true
          else
            agent_caps = MapSet.new(meta[:capabilities] || [])
            MapSet.subset?(MapSet.new(required_caps), agent_caps)
          end
        end)

      if candidates == [] do
        {:ok, nil}
      else
        # Score each candidate
        workloads = get_workloads(fleet_id)

        scored =
          candidates
          |> Enum.map(fn {agent_id, meta} ->
            workload = Map.get(workloads, agent_id, 0)
            state_score = if meta[:state] == "online", do: 0, else: 1
            squad_score = if task.squad_id && get_agent_squad_id(agent_id) == task.squad_id, do: 0, else: 1

            score = workload * 10 + state_score + squad_score
            {agent_id, score}
          end)
          |> Enum.sort_by(fn {_, score} -> score end)

        {best_agent, _score} = hd(scored)
        {:ok, best_agent}
      end
    end
  end

  # ════════════════════════════════════════════════════════════
  # Dependency Management
  # ════════════════════════════════════════════════════════════

  @doc "Check if all dependencies of a task are satisfied (done)."
  def check_dependencies(task_id) do
    with {:ok, task} <- get_task(task_id) do
      deps = task.depends_on || []

      if deps == [] do
        {:ok, :no_dependencies}
      else
        done_deps =
          from(t in KanbanTask,
            where: t.task_id in ^deps and t.lane == "done",
            select: t.task_id
          )
          |> Repo.all()
          |> MapSet.new()

        all_deps = MapSet.new(deps)
        unmet = MapSet.difference(all_deps, done_deps) |> MapSet.to_list()

        if unmet == [] do
          {:ok, :all_satisfied}
        else
          {:ok, {:blocked, unmet}}
        end
      end
    end
  end

  @doc """
  When a task completes, check all tasks that depend on it.
  If their dependencies are now all met, move them from backlog to ready.
  """
  def unblock_dependents(completed_task_id) do
    # Find tasks that depend on this one
    dependents =
      from(t in KanbanTask,
        where: ^completed_task_id in t.depends_on and t.lane in ["backlog"],
        select: t
      )
      |> Repo.all()

    Enum.each(dependents, fn dep ->
      case check_dependencies(dep.task_id) do
        {:ok, :all_satisfied} ->
          move_task(dep.task_id, "ready", "system", "dependencies satisfied (#{completed_task_id} completed)")

        _ ->
          :ok
      end
    end)
  end

  @doc "List all tasks with unmet dependencies in a fleet."
  def blocked_tasks(fleet_id) do
    from(t in KanbanTask,
      where: t.fleet_id == ^fleet_id and t.lane != "cancelled" and t.lane != "done",
      where: fragment("array_length(?, 1) > 0", t.depends_on),
      order_by: [asc: :inserted_at]
    )
    |> Repo.all()
    |> Enum.filter(fn task ->
      case check_dependencies(task.task_id) do
        {:ok, {:blocked, _}} -> true
        _ -> false
      end
    end)
  end

  # ════════════════════════════════════════════════════════════
  # Stats & Velocity
  # ════════════════════════════════════════════════════════════

  @doc "Board statistics: counts per lane, blockers, velocity."
  def board_stats(fleet_id) do
    lane_counts =
      from(t in KanbanTask,
        where: t.fleet_id == ^fleet_id,
        group_by: t.lane,
        select: {t.lane, count(t.id)}
      )
      |> Repo.all()
      |> Map.new()

    total = Enum.reduce(lane_counts, 0, fn {_, c}, acc -> acc + c end)

    blocked_count =
      from(t in KanbanTask,
        where: t.fleet_id == ^fleet_id and fragment("array_length(?, 1) > 0", t.blocked_by),
        where: t.lane not in ["done", "cancelled"],
        select: count(t.id)
      )
      |> Repo.one()

    %{
      "lanes" => lane_counts,
      "total" => total,
      "blocked" => blocked_count || 0,
      "velocity_24h" => velocity(fleet_id, 24),
      "velocity_7d" => velocity(fleet_id, 168),
      "avg_cycle_time_hours" => cycle_time(fleet_id)
    }
  end

  @doc "Number of tasks completed in the given period (hours)."
  def velocity(fleet_id, period_hours) do
    since = DateTime.utc_now() |> DateTime.add(-period_hours * 3600, :second)

    from(t in KanbanTask,
      where: t.fleet_id == ^fleet_id and t.lane == "done" and t.completed_at >= ^since,
      select: count(t.id)
    )
    |> Repo.one() || 0
  end

  @doc "Average cycle time (in_progress → done) in hours."
  def cycle_time(fleet_id) do
    result =
      from(t in KanbanTask,
        where: t.fleet_id == ^fleet_id and t.lane == "done"
          and not is_nil(t.started_at) and not is_nil(t.completed_at),
        select: avg(fragment("EXTRACT(EPOCH FROM ? - ?)", t.completed_at, t.started_at))
      )
      |> Repo.one()

    case result do
      nil -> nil
      seconds when is_float(seconds) -> Float.round(seconds / 3600, 1)
      %Decimal{} = d -> d |> Decimal.to_float() |> Kernel./(3600) |> Float.round(1)
    end
  end

  # ════════════════════════════════════════════════════════════
  # Human / AI Translation
  # ════════════════════════════════════════════════════════════

  @doc "Render a board as human-readable markdown."
  def format_board_human(board) when is_map(board) do
    lanes = ["backlog", "ready", "in_progress", "review", "done"]

    lanes
    |> Enum.map(fn lane ->
      tasks = Map.get(board, lane, [])
      header = "## #{lane_emoji(lane)} #{String.replace(lane, "_", " ") |> String.upcase()} (#{length(tasks)})"

      task_lines =
        tasks
        |> Enum.map(&format_task_human/1)
        |> Enum.join("\n")

      if tasks == [] do
        header <> "\n_empty_"
      else
        header <> "\n" <> task_lines
      end
    end)
    |> Enum.join("\n\n")
  end

  @doc "Render a single task as a human-friendly card."
  def format_task_human(%KanbanTask{} = t) do
    assigned = if t.assigned_to, do: " → #{t.assigned_to}", else: " (unassigned)"
    priority_icon = priority_emoji(t.priority)
    progress = if t.progress_pct > 0, do: " [#{t.progress_pct}%]", else: ""
    blocked = if (t.blocked_by || []) != [], do: " 🚫 BLOCKED", else: ""

    "- #{priority_icon} **#{t.task_id}** #{t.title}#{assigned}#{progress}#{blocked}"
  end

  @doc "Render board as compact JSON map (default for AI consumption)."
  def format_board_ai(board) when is_map(board) do
    board
    |> Enum.map(fn {lane, tasks} ->
      {lane, Enum.map(tasks, &KanbanTask.to_map/1)}
    end)
    |> Map.new()
  end

  # ════════════════════════════════════════════════════════════
  # History
  # ════════════════════════════════════════════════════════════

  @doc "Get lane transition history for a task."
  def task_history(task_id) do
    with {:ok, task} <- get_task(task_id) do
      history =
        from(h in KanbanTaskHistory,
          where: h.kanban_task_id == ^task.id,
          order_by: [asc: :inserted_at]
        )
        |> Repo.all()

      {:ok, history}
    end
  end

  # ════════════════════════════════════════════════════════════
  # Private Helpers
  # ════════════════════════════════════════════════════════════

  defp validate_transition(from_lane, to_lane) do
    valid_targets = Map.get(@valid_transitions, from_lane, [])

    if to_lane in valid_targets do
      :ok
    else
      {:error, {:invalid_transition, from_lane, to_lane, valid_targets}}
    end
  end

  defp record_history(kanban_task_id, from_lane, to_lane, changed_by, reason) do
    %KanbanTaskHistory{}
    |> KanbanTaskHistory.changeset(%{
      kanban_task_id: kanban_task_id,
      from_lane: from_lane,
      to_lane: to_lane,
      changed_by: changed_by,
      reason: reason
    })
    |> Repo.insert()
  end

  defp generate_task_id(fleet_id) do
    # Get the current max task number for this fleet
    max_num =
      from(t in KanbanTask,
        where: t.fleet_id == ^fleet_id,
        select: count(t.id)
      )
      |> Repo.one() || 0

    next = max_num + 1
    "T-#{String.pad_leading(Integer.to_string(next), 3, "0")}"
  end

  defp group_by_lane(tasks) do
    default = %{
      "backlog" => [],
      "ready" => [],
      "in_progress" => [],
      "review" => [],
      "done" => []
    }

    tasks
    |> Enum.group_by(& &1.lane)
    |> then(&Map.merge(default, &1))
  end

  defp find_task(fleet_id, agent_id, lane) do
    from(t in KanbanTask,
      where: t.fleet_id == ^fleet_id and t.assigned_to == ^agent_id and t.lane == ^lane,
      order_by: [
        fragment("CASE ? WHEN 'critical' THEN 0 WHEN 'high' THEN 1 WHEN 'medium' THEN 2 WHEN 'low' THEN 3 ELSE 4 END", t.priority),
        asc: t.position
      ],
      limit: 1
    )
    |> Repo.one()
  end

  defp find_unassigned_task(fleet_id, squad_id, agent_caps) do
    # First try squad tasks, then fleet tasks
    base_query =
      from(t in KanbanTask,
        where: t.fleet_id == ^fleet_id and t.lane == "ready" and is_nil(t.assigned_to),
        order_by: [
          fragment("CASE ? WHEN 'critical' THEN 0 WHEN 'high' THEN 1 WHEN 'medium' THEN 2 WHEN 'low' THEN 3 ELSE 4 END", t.priority),
          asc: t.position
        ]
      )

    # Try squad-scoped first if agent has a squad
    task =
      if squad_id do
        from(t in base_query, where: t.squad_id == ^squad_id, limit: 1)
        |> Repo.one()
      end

    task = task || (from(t in base_query, limit: 1) |> Repo.one())

    # Filter by capabilities if the task requires them
    case task do
      %KanbanTask{requires_capabilities: []} -> task
      %KanbanTask{requires_capabilities: nil} -> task
      %KanbanTask{requires_capabilities: required} ->
        agent_cap_set = MapSet.new(agent_caps)
        if MapSet.subset?(MapSet.new(required), agent_cap_set), do: task, else: nil
      nil -> nil
    end
  end

  defp get_agent_capabilities(agent_id, fleet_id) do
    # Try presence first, then DB
    case FleetPresence.list("fleet:#{fleet_id}") |> Map.get(agent_id) do
      %{metas: [meta | _]} -> meta[:capabilities] || []
      _ ->
        case Hub.Auth.find_agent(agent_id) do
          {:ok, agent} -> agent.capabilities || []
          _ -> []
        end
    end
  end

  defp get_agent_squad_id(agent_id) do
    case Hub.Auth.find_agent(agent_id) do
      {:ok, agent} -> agent.squad_id
      _ -> nil
    end
  end

  defp get_workloads(fleet_id) do
    from(t in KanbanTask,
      where: t.fleet_id == ^fleet_id and t.lane == "in_progress" and not is_nil(t.assigned_to),
      group_by: t.assigned_to,
      select: {t.assigned_to, count(t.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp ensure_string_keys_to_atoms(attrs) when is_map(attrs) do
    Enum.reduce(attrs, %{}, fn
      {key, val}, acc when is_binary(key) ->
        atom_key = try do
          String.to_existing_atom(key)
        rescue
          ArgumentError -> String.to_atom(key)
        end
        Map.put(acc, atom_key, val)

      {key, val}, acc ->
        Map.put(acc, key, val)
    end)
  end

  defp lane_emoji("backlog"), do: "📋"
  defp lane_emoji("ready"), do: "🟢"
  defp lane_emoji("in_progress"), do: "🔵"
  defp lane_emoji("review"), do: "🟡"
  defp lane_emoji("done"), do: "✅"
  defp lane_emoji(_), do: "⬜"

  defp priority_emoji("critical"), do: "🔴"
  defp priority_emoji("high"), do: "🟠"
  defp priority_emoji("medium"), do: "🟡"
  defp priority_emoji("low"), do: "⚪"
  defp priority_emoji(_), do: "⬜"
end
