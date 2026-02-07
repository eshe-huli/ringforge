defmodule Hub.Task do
  @moduledoc """
  Ephemeral task store for fleet work distribution.

  Tasks live in ETS, are routed to capable agents, and expire after TTL.
  No database persistence — tasks are transient coordination artifacts.

  ## Lifecycle

      :pending → :assigned → :running → :completed | :failed | :timeout
  """

  @table :hub_tasks
  @counter_table :hub_task_counters
  @default_ttl_ms 30_000
  @max_ttl_ms 300_000

  defstruct [
    :task_id,
    :fleet_id,
    :requester_id,
    :type,
    :prompt,
    :capabilities_required,
    :assigned_to,
    :status,
    :result,
    :error,
    :priority,
    :ttl_ms,
    :created_at,
    :assigned_at,
    :completed_at,
    :correlation_id
  ]

  @type t :: %__MODULE__{
    task_id: String.t(),
    fleet_id: String.t(),
    requester_id: String.t(),
    type: String.t(),
    prompt: String.t(),
    capabilities_required: [String.t()],
    assigned_to: String.t() | nil,
    status: :pending | :assigned | :running | :completed | :failed | :timeout,
    result: any(),
    error: String.t() | nil,
    priority: :low | :normal | :high,
    ttl_ms: non_neg_integer(),
    created_at: DateTime.t(),
    assigned_at: DateTime.t() | nil,
    completed_at: DateTime.t() | nil,
    correlation_id: String.t() | nil
  }

  # ── Init ──────────────────────────────────────────────────

  @doc "Create ETS tables. Called from Application supervisor."
  def init do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(@counter_table, [:named_table, :set, :public])
    # Initialize daily counter
    today = Date.utc_today() |> Date.to_iso8601()
    :ets.insert_new(@counter_table, {{:daily, today}, 0})
    :ok
  end

  # ── Create ────────────────────────────────────────────────

  @doc "Create a new task and insert into ETS. Returns the task struct."
  def create(attrs) when is_map(attrs) do
    now = DateTime.utc_now()
    ttl = parse_ttl(attrs[:ttl_ms] || attrs["ttl_ms"])
    priority = parse_priority(attrs[:priority] || attrs["priority"])

    task = %__MODULE__{
      task_id: "task_" <> gen_id(),
      fleet_id: attrs[:fleet_id] || attrs["fleet_id"],
      requester_id: attrs[:requester_id] || attrs["requester_id"],
      type: attrs[:type] || attrs["type"] || "general",
      prompt: attrs[:prompt] || attrs["prompt"],
      capabilities_required: attrs[:capabilities_required] || attrs["capabilities_required"] || [],
      assigned_to: nil,
      status: :pending,
      result: nil,
      error: nil,
      priority: priority,
      ttl_ms: ttl,
      created_at: now,
      assigned_at: nil,
      completed_at: nil,
      correlation_id: attrs[:correlation_id] || attrs["correlation_id"]
    }

    :ets.insert(@table, {task.task_id, task})
    increment_daily_counter()
    {:ok, task}
  end

  # ── Assign ────────────────────────────────────────────────

  @doc "Mark a task as assigned to an agent."
  def assign(task_id, agent_id) do
    case get(task_id) do
      {:ok, %{status: :pending} = task} ->
        updated = %{task | status: :assigned, assigned_to: agent_id, assigned_at: DateTime.utc_now()}
        :ets.insert(@table, {task_id, updated})
        {:ok, updated}

      {:ok, %{status: status}} ->
        {:error, {:invalid_status, status}}

      :not_found ->
        {:error, :not_found}
    end
  end

  # ── Start (claim) ─────────────────────────────────────────

  @doc "Mark a task as running (worker claimed it)."
  def start(task_id) do
    case get(task_id) do
      {:ok, %{status: :assigned} = task} ->
        updated = %{task | status: :running}
        :ets.insert(@table, {task_id, updated})
        {:ok, updated}

      {:ok, %{status: status}} ->
        {:error, {:invalid_status, status}}

      :not_found ->
        {:error, :not_found}
    end
  end

  # ── Complete ──────────────────────────────────────────────

  @doc "Mark a task as completed with a result payload."
  def complete(task_id, result) do
    case get(task_id) do
      {:ok, %{status: status} = task} when status in [:assigned, :running] ->
        updated = %{task | status: :completed, result: result, completed_at: DateTime.utc_now()}
        :ets.insert(@table, {task_id, updated})
        {:ok, updated}

      {:ok, %{status: status}} ->
        {:error, {:invalid_status, status}}

      :not_found ->
        {:error, :not_found}
    end
  end

  # ── Fail ──────────────────────────────────────────────────

  @doc "Mark a task as failed with an error message."
  def fail(task_id, error) do
    case get(task_id) do
      {:ok, %{status: status} = task} when status in [:pending, :assigned, :running] ->
        updated = %{task | status: :failed, error: error, completed_at: DateTime.utc_now()}
        :ets.insert(@table, {task_id, updated})
        {:ok, updated}

      {:ok, %{status: status}} ->
        {:error, {:invalid_status, status}}

      :not_found ->
        {:error, :not_found}
    end
  end

  # ── Timeout ───────────────────────────────────────────────

  @doc "Mark a task as timed out."
  def timeout(task_id) do
    case get(task_id) do
      {:ok, %{status: status} = task} when status in [:pending, :assigned, :running] ->
        updated = %{task | status: :timeout, completed_at: DateTime.utc_now()}
        :ets.insert(@table, {task_id, updated})
        {:ok, updated}

      _ ->
        :ok
    end
  end

  # ── Get ───────────────────────────────────────────────────

  @doc "Get a task by task_id."
  def get(task_id) do
    case :ets.lookup(@table, task_id) do
      [{^task_id, task}] -> {:ok, task}
      [] -> :not_found
    end
  end

  # ── Pending for Fleet ─────────────────────────────────────

  @doc "List pending tasks for a fleet, ordered by priority (high first)."
  def pending_for_fleet(fleet_id) do
    :ets.tab2list(@table)
    |> Enum.map(fn {_id, task} -> task end)
    |> Enum.filter(fn t -> t.fleet_id == fleet_id and t.status == :pending end)
    |> Enum.sort_by(fn t -> priority_sort(t.priority) end)
  end

  # ── Active tasks (assigned/running) ───────────────────────

  @doc "List active (assigned or running) tasks."
  def active_tasks do
    :ets.tab2list(@table)
    |> Enum.map(fn {_id, task} -> task end)
    |> Enum.filter(fn t -> t.status in [:assigned, :running] end)
  end

  # ── All tasks (for cleanup) ───────────────────────────────

  @doc "List all tasks."
  def all_tasks do
    :ets.tab2list(@table)
    |> Enum.map(fn {_id, task} -> task end)
  end

  # ── Cleanup Expired ───────────────────────────────────────

  @doc "Delete tasks that are past TTL and in terminal states for > 5 min."
  def cleanup_expired do
    now = DateTime.utc_now()
    cleanup_cutoff_ms = 300_000  # 5 minutes

    all_tasks()
    |> Enum.each(fn task ->
      age_ms = DateTime.diff(now, task.created_at, :millisecond)
      cond do
        # Terminal tasks older than 5 minutes
        task.status in [:completed, :failed, :timeout] ->
          completed_age = DateTime.diff(now, task.completed_at || task.created_at, :millisecond)
          if completed_age > cleanup_cutoff_ms do
            :ets.delete(@table, task.task_id)
          end

        # Active tasks past TTL
        task.status in [:pending, :assigned, :running] and age_ms > task.ttl_ms ->
          # These should be caught by timeout check, but clean up just in case
          :ets.delete(@table, task.task_id)

        true ->
          :ok
      end
    end)
  end

  # ── Daily Counter ─────────────────────────────────────────

  @doc "Get the number of tasks created today."
  def tasks_today do
    today = Date.utc_today() |> Date.to_iso8601()
    case :ets.lookup(@counter_table, {:daily, today}) do
      [{{:daily, ^today}, count}] -> count
      [] -> 0
    end
  end

  # ── Serialization ─────────────────────────────────────────

  @doc "Serialize a task struct to a JSON-friendly map."
  def to_map(%__MODULE__{} = task) do
    %{
      "task_id" => task.task_id,
      "fleet_id" => task.fleet_id,
      "requester_id" => task.requester_id,
      "type" => task.type,
      "prompt" => task.prompt,
      "capabilities_required" => task.capabilities_required,
      "assigned_to" => task.assigned_to,
      "status" => Atom.to_string(task.status),
      "result" => task.result,
      "error" => task.error,
      "priority" => Atom.to_string(task.priority),
      "ttl_ms" => task.ttl_ms,
      "created_at" => task.created_at && DateTime.to_iso8601(task.created_at),
      "assigned_at" => task.assigned_at && DateTime.to_iso8601(task.assigned_at),
      "completed_at" => task.completed_at && DateTime.to_iso8601(task.completed_at),
      "correlation_id" => task.correlation_id
    }
  end

  # ── Private ───────────────────────────────────────────────

  defp gen_id do
    <<a::32, b::16, c::16>> = :crypto.strong_rand_bytes(8)
    Base.encode16(<<a::32, b::16, c::16>>, case: :lower)
  end

  defp parse_ttl(nil), do: @default_ttl_ms
  defp parse_ttl(ms) when is_integer(ms) and ms > 0, do: min(ms, @max_ttl_ms)
  defp parse_ttl(_), do: @default_ttl_ms

  defp parse_priority("high"), do: :high
  defp parse_priority("low"), do: :low
  defp parse_priority(:high), do: :high
  defp parse_priority(:low), do: :low
  defp parse_priority(_), do: :normal

  defp priority_sort(:high), do: 0
  defp priority_sort(:normal), do: 1
  defp priority_sort(:low), do: 2

  defp increment_daily_counter do
    today = Date.utc_today() |> Date.to_iso8601()
    :ets.update_counter(@counter_table, {:daily, today}, {2, 1}, {{:daily, today}, 0})
  end
end
