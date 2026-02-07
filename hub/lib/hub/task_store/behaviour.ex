defmodule Hub.TaskStore.Behaviour do
  @moduledoc """
  Behaviour for pluggable task storage backends.

  Implementations must support the same interface as the original
  ETS-based `Hub.Task` module for task CRUD and querying.
  """

  @type task :: Hub.Task.t()
  @type task_id :: String.t()
  @type fleet_id :: String.t()
  @type agent_id :: String.t()

  @callback init() :: :ok
  @callback create(map()) :: {:ok, task()}
  @callback get(task_id()) :: {:ok, task()} | :not_found
  @callback assign(task_id(), agent_id()) :: {:ok, task()} | {:error, any()}
  @callback start(task_id()) :: {:ok, task()} | {:error, any()}
  @callback complete(task_id(), any()) :: {:ok, task()} | {:error, any()}
  @callback fail(task_id(), String.t()) :: {:ok, task()} | {:error, any()}
  @callback timeout(task_id()) :: {:ok, task()} | :ok
  @callback pending_for_fleet(fleet_id()) :: [task()]
  @callback active_tasks() :: [task()]
  @callback all_tasks() :: [task()]
  @callback cleanup_expired() :: :ok
  @callback tasks_today() :: non_neg_integer()
end
