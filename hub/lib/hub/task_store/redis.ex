defmodule Hub.TaskStore.Redis do
  @moduledoc """
  Redis-backed distributed task store.

  Provides the same interface as the ETS task store but persists tasks
  in Redis, enabling shared state across multiple Hub nodes.

  ## Key Schema

  - `rf:task:{task_id}` — Hash with all task fields (TTL: task TTL + 10min)
  - `rf:tasks:pending:{fleet_id}` — Sorted Set by priority (score: priority rank)
  - `rf:tasks:active` — Set of task_ids in assigned/running state
  - `rf:tasks:agent:{agent_id}` — Set of task_ids assigned to this agent
  - `rf:tasks:daily:{date}` — Counter for tasks created today (TTL: 48h)

  All keys have TTLs for automatic cleanup.
  """

  @behaviour Hub.TaskStore.Behaviour

  require Logger

  @prefix "rf:task:"
  @pending_prefix "rf:tasks:pending:"
  @active_key "rf:tasks:active"
  @agent_prefix "rf:tasks:agent:"
  @daily_prefix "rf:tasks:daily:"
  @task_ttl_buffer_s 600  # 10 min buffer beyond task TTL
  @cleanup_ttl_s 300       # 5 min for terminal tasks
  @daily_ttl_s 172_800     # 48 hours

  @impl true
  def init do
    # Ensure Redix connection is available
    case Redix.command(redis_conn(), ["PING"]) do
      {:ok, "PONG"} ->
        Logger.info("[TaskStore.Redis] Connected to Redis")
        :ok

      {:error, reason} ->
        Logger.error("[TaskStore.Redis] Redis connection failed: #{inspect(reason)}")
        :ok
    end
  end

  @impl true
  def create(attrs) do
    now = DateTime.utc_now()
    ttl_ms = parse_ttl(attrs[:ttl_ms] || attrs["ttl_ms"])
    priority = parse_priority(attrs[:priority] || attrs["priority"])
    task_id = "task_" <> gen_id()
    fleet_id = attrs[:fleet_id] || attrs["fleet_id"]

    task = %Hub.Task{
      task_id: task_id,
      fleet_id: fleet_id,
      requester_id: attrs[:requester_id] || attrs["requester_id"],
      type: attrs[:type] || attrs["type"] || "general",
      prompt: attrs[:prompt] || attrs["prompt"],
      capabilities_required: attrs[:capabilities_required] || attrs["capabilities_required"] || [],
      assigned_to: nil,
      status: :pending,
      result: nil,
      error: nil,
      priority: priority,
      ttl_ms: ttl_ms,
      created_at: now,
      assigned_at: nil,
      completed_at: nil,
      correlation_id: attrs[:correlation_id] || attrs["correlation_id"]
    }

    key = @prefix <> task_id
    ttl_s = div(ttl_ms, 1000) + @task_ttl_buffer_s

    commands = [
      ["HSET", key | task_to_redis_pairs(task)],
      ["EXPIRE", key, to_string(ttl_s)],
      ["ZADD", @pending_prefix <> fleet_id, to_string(priority_score(priority)), task_id]
    ]

    Redix.pipeline(redis_conn(), commands)

    # Increment daily counter
    today = Date.utc_today() |> Date.to_iso8601()
    daily_key = @daily_prefix <> today
    Redix.pipeline(redis_conn(), [
      ["INCR", daily_key],
      ["EXPIRE", daily_key, to_string(@daily_ttl_s)]
    ])

    Hub.Telemetry.execute([:hub, :task, :submitted], %{count: 1}, %{
      fleet_id: fleet_id,
      task_id: task_id
    })

    {:ok, task}
  end

  @impl true
  def get(task_id) do
    key = @prefix <> task_id

    case Redix.command(redis_conn(), ["HGETALL", key]) do
      {:ok, []} -> :not_found
      {:ok, pairs} -> {:ok, redis_pairs_to_task(pairs)}
      {:error, _} -> :not_found
    end
  end

  @impl true
  def assign(task_id, agent_id) do
    case get(task_id) do
      {:ok, %{status: :pending} = task} ->
        now = DateTime.utc_now()
        updated = %{task | status: :assigned, assigned_to: agent_id, assigned_at: now}

        key = @prefix <> task_id
        commands = [
          ["HSET", key, "status", "assigned", "assigned_to", agent_id,
           "assigned_at", DateTime.to_iso8601(now)],
          ["ZREM", @pending_prefix <> task.fleet_id, task_id],
          ["SADD", @active_key, task_id],
          ["SADD", @agent_prefix <> agent_id, task_id]
        ]

        Redix.pipeline(redis_conn(), commands)
        {:ok, updated}

      {:ok, %{status: status}} ->
        {:error, {:invalid_status, status}}

      :not_found ->
        {:error, :not_found}
    end
  end

  @impl true
  def start(task_id) do
    case get(task_id) do
      {:ok, %{status: :assigned} = task} ->
        updated = %{task | status: :running}
        Redix.command(redis_conn(), ["HSET", @prefix <> task_id, "status", "running"])
        {:ok, updated}

      {:ok, %{status: status}} ->
        {:error, {:invalid_status, status}}

      :not_found ->
        {:error, :not_found}
    end
  end

  @impl true
  def complete(task_id, result) do
    case get(task_id) do
      {:ok, %{status: status} = task} when status in [:assigned, :running] ->
        now = DateTime.utc_now()
        updated = %{task | status: :completed, result: result, completed_at: now}
        result_json = Jason.encode!(result)

        key = @prefix <> task_id
        commands = [
          ["HSET", key, "status", "completed", "result", result_json,
           "completed_at", DateTime.to_iso8601(now)],
          ["EXPIRE", key, to_string(@cleanup_ttl_s)],
          ["SREM", @active_key, task_id]
        ]

        commands =
          if task.assigned_to do
            commands ++ [["SREM", @agent_prefix <> task.assigned_to, task_id]]
          else
            commands
          end

        Redix.pipeline(redis_conn(), commands)

        duration_ms = DateTime.diff(now, task.created_at, :millisecond)
        Hub.Telemetry.execute([:hub, :task, :completed], %{count: 1, duration_ms: duration_ms}, %{
          fleet_id: task.fleet_id,
          task_id: task_id
        })

        {:ok, updated}

      {:ok, %{status: status}} ->
        {:error, {:invalid_status, status}}

      :not_found ->
        {:error, :not_found}
    end
  end

  @impl true
  def fail(task_id, error) do
    case get(task_id) do
      {:ok, %{status: status} = task} when status in [:pending, :assigned, :running] ->
        now = DateTime.utc_now()
        updated = %{task | status: :failed, error: error, completed_at: now}

        key = @prefix <> task_id
        commands = [
          ["HSET", key, "status", "failed", "error", error,
           "completed_at", DateTime.to_iso8601(now)],
          ["EXPIRE", key, to_string(@cleanup_ttl_s)],
          ["SREM", @active_key, task_id],
          ["ZREM", @pending_prefix <> task.fleet_id, task_id]
        ]

        commands =
          if task.assigned_to do
            commands ++ [["SREM", @agent_prefix <> task.assigned_to, task_id]]
          else
            commands
          end

        Redix.pipeline(redis_conn(), commands)

        Hub.Telemetry.execute([:hub, :task, :failed], %{count: 1}, %{
          fleet_id: task.fleet_id,
          task_id: task_id
        })

        {:ok, updated}

      {:ok, %{status: status}} ->
        {:error, {:invalid_status, status}}

      :not_found ->
        {:error, :not_found}
    end
  end

  @impl true
  def timeout(task_id) do
    case get(task_id) do
      {:ok, %{status: status} = task} when status in [:pending, :assigned, :running] ->
        now = DateTime.utc_now()
        updated = %{task | status: :timeout, completed_at: now}

        key = @prefix <> task_id
        commands = [
          ["HSET", key, "status", "timeout", "completed_at", DateTime.to_iso8601(now)],
          ["EXPIRE", key, to_string(@cleanup_ttl_s)],
          ["SREM", @active_key, task_id],
          ["ZREM", @pending_prefix <> task.fleet_id, task_id]
        ]

        commands =
          if task.assigned_to do
            commands ++ [["SREM", @agent_prefix <> task.assigned_to, task_id]]
          else
            commands
          end

        Redix.pipeline(redis_conn(), commands)
        {:ok, updated}

      _ ->
        :ok
    end
  end

  @impl true
  def pending_for_fleet(fleet_id) do
    key = @pending_prefix <> fleet_id

    case Redix.command(redis_conn(), ["ZRANGE", key, "0", "-1"]) do
      {:ok, task_ids} ->
        task_ids
        |> Enum.map(fn id ->
          case get(id) do
            {:ok, task} -> task
            :not_found ->
              # Stale reference — clean up
              Redix.command(redis_conn(), ["ZREM", key, id])
              nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(fn t -> priority_sort(t.priority) end)

      {:error, _} ->
        []
    end
  end

  @impl true
  def active_tasks do
    case Redix.command(redis_conn(), ["SMEMBERS", @active_key]) do
      {:ok, task_ids} ->
        task_ids
        |> Enum.map(fn id ->
          case get(id) do
            {:ok, task} -> task
            :not_found ->
              Redix.command(redis_conn(), ["SREM", @active_key, id])
              nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      {:error, _} ->
        []
    end
  end

  @impl true
  def all_tasks do
    # Scan for all task keys — note: this is expensive and should only
    # be used for cleanup, not hot paths
    scan_keys(@prefix <> "*")
    |> Enum.map(fn key ->
      task_id = String.replace_prefix(key, @prefix, "")
      case get(task_id) do
        {:ok, task} -> task
        :not_found -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  @impl true
  def cleanup_expired do
    # Redis TTLs handle most cleanup automatically.
    # This just cleans stale set references.
    case Redix.command(redis_conn(), ["SMEMBERS", @active_key]) do
      {:ok, task_ids} ->
        Enum.each(task_ids, fn id ->
          case Redix.command(redis_conn(), ["EXISTS", @prefix <> id]) do
            {:ok, 0} -> Redix.command(redis_conn(), ["SREM", @active_key, id])
            _ -> :ok
          end
        end)

      _ ->
        :ok
    end

    :ok
  end

  @impl true
  def tasks_today do
    today = Date.utc_today() |> Date.to_iso8601()

    case Redix.command(redis_conn(), ["GET", @daily_prefix <> today]) do
      {:ok, nil} -> 0
      {:ok, count} -> String.to_integer(count)
      {:error, _} -> 0
    end
  end

  # ── Private: Redis serialization ──────────────────────────

  defp task_to_redis_pairs(%Hub.Task{} = task) do
    [
      "task_id", task.task_id,
      "fleet_id", task.fleet_id,
      "requester_id", task.requester_id || "",
      "type", task.type || "general",
      "prompt", task.prompt || "",
      "capabilities_required", Jason.encode!(task.capabilities_required || []),
      "assigned_to", task.assigned_to || "",
      "status", Atom.to_string(task.status),
      "result", if(task.result, do: Jason.encode!(task.result), else: ""),
      "error", task.error || "",
      "priority", Atom.to_string(task.priority),
      "ttl_ms", to_string(task.ttl_ms),
      "created_at", if(task.created_at, do: DateTime.to_iso8601(task.created_at), else: ""),
      "assigned_at", if(task.assigned_at, do: DateTime.to_iso8601(task.assigned_at), else: ""),
      "completed_at", if(task.completed_at, do: DateTime.to_iso8601(task.completed_at), else: ""),
      "correlation_id", task.correlation_id || ""
    ]
  end

  defp redis_pairs_to_task(pairs) do
    map =
      pairs
      |> Enum.chunk_every(2)
      |> Map.new(fn [k, v] -> {k, v} end)

    %Hub.Task{
      task_id: map["task_id"],
      fleet_id: map["fleet_id"],
      requester_id: nilify(map["requester_id"]),
      type: map["type"] || "general",
      prompt: map["prompt"],
      capabilities_required: safe_decode_json(map["capabilities_required"], []),
      assigned_to: nilify(map["assigned_to"]),
      status: String.to_existing_atom(map["status"]),
      result: safe_decode_json(map["result"], nil),
      error: nilify(map["error"]),
      priority: String.to_existing_atom(map["priority"] || "normal"),
      ttl_ms: String.to_integer(map["ttl_ms"] || "30000"),
      created_at: parse_datetime(map["created_at"]),
      assigned_at: parse_datetime(map["assigned_at"]),
      completed_at: parse_datetime(map["completed_at"]),
      correlation_id: nilify(map["correlation_id"])
    }
  end

  defp nilify(""), do: nil
  defp nilify(nil), do: nil
  defp nilify(val), do: val

  defp parse_datetime(""), do: nil
  defp parse_datetime(nil), do: nil

  defp parse_datetime(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp safe_decode_json("", default), do: default
  defp safe_decode_json(nil, default), do: default

  defp safe_decode_json(json, default) do
    case Jason.decode(json) do
      {:ok, val} -> val
      _ -> default
    end
  end

  defp scan_keys(pattern) do
    scan_keys_acc(pattern, "0", [])
  end

  defp scan_keys_acc(pattern, cursor, acc) do
    case Redix.command(redis_conn(), ["SCAN", cursor, "MATCH", pattern, "COUNT", "100"]) do
      {:ok, [new_cursor, keys]} ->
        acc = acc ++ keys
        if new_cursor == "0", do: acc, else: scan_keys_acc(pattern, new_cursor, acc)

      {:error, _} ->
        acc
    end
  end

  defp redis_conn, do: Hub.Redis

  defp gen_id do
    <<a::32, b::16, c::16>> = :crypto.strong_rand_bytes(8)
    Base.encode16(<<a::32, b::16, c::16>>, case: :lower)
  end

  defp parse_ttl(nil), do: 30_000
  defp parse_ttl(ms) when is_integer(ms) and ms > 0, do: min(ms, 300_000)
  defp parse_ttl(_), do: 30_000

  defp parse_priority("high"), do: :high
  defp parse_priority("low"), do: :low
  defp parse_priority(:high), do: :high
  defp parse_priority(:low), do: :low
  defp parse_priority(_), do: :normal

  defp priority_score(:high), do: 0
  defp priority_score(:normal), do: 1
  defp priority_score(:low), do: 2
  defp priority_score(_), do: 1

  defp priority_sort(:high), do: 0
  defp priority_sort(:normal), do: 1
  defp priority_sort(:low), do: 2
end
