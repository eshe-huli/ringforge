defmodule Hub.TaskStore do
  @moduledoc """
  Unified task store dispatcher.

  Routes calls to the configured backend (ETS or Redis) based on
  the `:hub, Hub.TaskStore, :adapter` config. Defaults to ETS.

  ## Configuration

      config :hub, Hub.TaskStore,
        adapter: Hub.TaskStore.ETS  # or Hub.TaskStore.Redis
  """

  @doc "Returns the configured adapter module."
  def adapter do
    config = Application.get_env(:hub, __MODULE__, [])
    Keyword.get(config, :adapter, Hub.TaskStore.ETS)
  end

  @doc "Initialize the task store backend."
  def init, do: adapter().init()

  @doc "Create a new task."
  def create(attrs), do: adapter().create(attrs)

  @doc "Get a task by ID."
  def get(task_id), do: adapter().get(task_id)

  @doc "Assign a task to an agent."
  def assign(task_id, agent_id), do: adapter().assign(task_id, agent_id)

  @doc "Mark a task as started/running."
  def start(task_id), do: adapter().start(task_id)

  @doc "Complete a task with a result."
  def complete(task_id, result), do: adapter().complete(task_id, result)

  @doc "Fail a task with an error."
  def fail(task_id, error), do: adapter().fail(task_id, error)

  @doc "Mark a task as timed out."
  def timeout(task_id), do: adapter().timeout(task_id)

  @doc "List pending tasks for a fleet."
  def pending_for_fleet(fleet_id), do: adapter().pending_for_fleet(fleet_id)

  @doc "List active (assigned/running) tasks."
  def active_tasks, do: adapter().active_tasks()

  @doc "List all tasks."
  def all_tasks, do: adapter().all_tasks()

  @doc "Cleanup expired tasks."
  def cleanup_expired, do: adapter().cleanup_expired()

  @doc "Get the number of tasks created today."
  def tasks_today, do: adapter().tasks_today()
end
