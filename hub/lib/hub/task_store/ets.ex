defmodule Hub.TaskStore.ETS do
  @moduledoc """
  ETS-backed task store — the default single-node implementation.

  Delegates to `Hub.Task` which manages the ETS tables directly.
  This module exists as the explicit backend behind the `Hub.TaskStore`
  behaviour so that `Hub.TaskStore.adapter()` can dispatch uniformly.
  """

  @behaviour Hub.TaskStore.Behaviour

  @impl true
  defdelegate init(), to: Hub.Task

  @impl true
  defdelegate create(attrs), to: Hub.Task

  @impl true
  defdelegate get(task_id), to: Hub.Task

  @impl true
  defdelegate assign(task_id, agent_id), to: Hub.Task

  @impl true
  defdelegate start(task_id), to: Hub.Task

  @impl true
  defdelegate complete(task_id, result), to: Hub.Task

  @impl true
  defdelegate fail(task_id, error), to: Hub.Task

  @impl true
  defdelegate timeout(task_id), to: Hub.Task

  @impl true
  defdelegate pending_for_fleet(fleet_id), to: Hub.Task

  @impl true
  defdelegate active_tasks(), to: Hub.Task

  @impl true
  defdelegate all_tasks(), to: Hub.Task

  @impl true
  defdelegate cleanup_expired(), to: Hub.Task

  @impl true
  defdelegate tasks_today(), to: Hub.Task
end
