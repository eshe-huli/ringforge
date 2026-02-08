defmodule Hub.Messaging.Threads do
  @moduledoc """
  Conversation threads — structured, contextual message grouping.

  Threads can be:
  - DM threads: between 2+ agents
  - Squad threads: visible to all squad members
  - Task threads: linked to a kanban task, auto-close when task completes
  - Escalation threads: created by the escalation system

  Messages within threads are stored in StorePort:
  Key format: "thr_msg:{thread_id}:{timestamp}:{message_id}"
  """

  import Ecto.Query
  alias Hub.Repo
  alias Hub.Schemas.MessageThread
  alias Hub.StorePort

  require Logger

  @pubsub Hub.PubSub
  @base62 ~c"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

  # ════════════════════════════════════════════════════════════
  # Thread CRUD
  # ════════════════════════════════════════════════════════════

  @doc """
  Create a new thread. Auto-generates thread_id "thr_<base62(12)>".

  Required attrs: :subject, :fleet_id, :tenant_id, :created_by
  Optional: :scope, :participant_ids, :task_id, :squad_id, :metadata
  """
  def create_thread(attrs) when is_map(attrs) do
    thread_id = "thr_#{base62_random(12)}"

    full_attrs =
      attrs
      |> Map.put(:thread_id, thread_id)
      |> Map.put_new(:participant_ids, [])
      |> ensure_creator_is_participant()

    %MessageThread{}
    |> MessageThread.changeset(full_attrs)
    |> Repo.insert()
  end

  @doc """
  Get a thread by its human-readable thread_id (e.g. "thr_abc123").
  """
  def get_thread(thread_id) when is_binary(thread_id) do
    case Repo.one(from t in MessageThread, where: t.thread_id == ^thread_id) do
      nil -> {:error, :not_found}
      thread -> {:ok, thread}
    end
  end

  @doc """
  List threads for a fleet with optional filters.

  ## Options
  - `:scope` - filter by scope ("dm", "squad", "task", "escalation")
  - `:status` - filter by status ("open", "closed", "archived"), default "open"
  - `:participant` - filter to threads containing this agent_id
  - `:task_id` - filter to threads linked to this task
  - `:limit` - max results (default 50)
  """
  def list_threads(fleet_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    query =
      from(t in MessageThread,
        where: t.fleet_id == ^fleet_id,
        order_by: [desc: :last_message_at, desc: :inserted_at],
        limit: ^limit
      )

    query = if scope = Keyword.get(opts, :scope) do
      from(t in query, where: t.scope == ^scope)
    else
      query
    end

    query = if status = Keyword.get(opts, :status) do
      from(t in query, where: t.status == ^status)
    else
      from(t in query, where: t.status == "open")
    end

    query = if participant = Keyword.get(opts, :participant) do
      from(t in query, where: ^participant in t.participant_ids)
    else
      query
    end

    query = if task_id = Keyword.get(opts, :task_id) do
      from(t in query, where: t.task_id == ^task_id)
    else
      query
    end

    Repo.all(query)
  end

  @doc """
  Get all open threads where the given agent is a participant.
  """
  def my_threads(agent_id, fleet_id) do
    from(t in MessageThread,
      where: t.fleet_id == ^fleet_id and ^agent_id in t.participant_ids,
      where: t.status == "open",
      order_by: [desc: :last_message_at, desc: :inserted_at]
    )
    |> Repo.all()
  end

  # ════════════════════════════════════════════════════════════
  # Messages (StorePort-backed)
  # ════════════════════════════════════════════════════════════

  @doc """
  Add a message to a thread. Stores in StorePort, updates thread counters,
  and broadcasts via PubSub.

  ## message_attrs
  - `:body` (required) - message text
  - `:refs` - list of references (task IDs, etc.)
  - `:metadata` - additional metadata map
  """
  def add_message(thread_id, agent_id, message_attrs) when is_map(message_attrs) do
    with {:ok, thread} <- get_thread(thread_id) do
      message_id = "msg_#{base62_random(12)}"
      now = DateTime.utc_now()
      timestamp = DateTime.to_iso8601(now)

      message = %{
        "id" => message_id,
        "thread_id" => thread_id,
        "from" => agent_id,
        "body" => Map.get(message_attrs, :body) || Map.get(message_attrs, "body", ""),
        "refs" => Map.get(message_attrs, :refs) || Map.get(message_attrs, "refs", []),
        "metadata" => Map.get(message_attrs, :metadata) || Map.get(message_attrs, "metadata", %{}),
        "timestamp" => timestamp
      }

      # Store in StorePort: "thr_msg:{thread_id}:{timestamp}:{message_id}"
      store_key = "thr_msg:#{thread_id}:#{timestamp}:#{message_id}"
      json = Jason.encode!(message)

      case StorePort.put_document(store_key, json) do
        :ok ->
          # Update thread counters
          thread
          |> MessageThread.changeset(%{
            message_count: thread.message_count + 1,
            last_message_at: now
          })
          |> Repo.update()

          # Auto-add sender as participant if not already
          unless agent_id in thread.participant_ids do
            add_participant(thread_id, agent_id)
          end

          # Broadcast to thread topic
          Phoenix.PubSub.broadcast(
            @pubsub,
            "thread:#{thread_id}",
            {:thread_message, message}
          )

          {:ok, message}

        {:error, reason} ->
          Logger.warning("[Threads] Failed to store message: #{inspect(reason)}")
          {:error, :store_failed}
      end
    end
  end

  @doc """
  Retrieve messages from a thread.

  ## Options
  - `:limit` - max messages to return (default 50)
  - `:before` - only messages before this ISO8601 timestamp
  """
  def thread_messages(thread_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    before = Keyword.get(opts, :before)
    prefix = "thr_msg:#{thread_id}:"

    case StorePort.list_documents() do
      {:ok, ids} ->
        messages =
          ids
          |> Enum.filter(&String.starts_with?(&1, prefix))
          |> Enum.sort()
          |> maybe_filter_before(before, prefix)
          |> Enum.take(-limit)
          |> Enum.map(&fetch_message/1)
          |> Enum.reject(&is_nil/1)

        {:ok, messages}

      {:error, reason} ->
        Logger.warning("[Threads] Failed to list messages: #{inspect(reason)}")
        {:ok, []}
    end
  end

  # ════════════════════════════════════════════════════════════
  # Thread Lifecycle
  # ════════════════════════════════════════════════════════════

  @doc """
  Close a thread with a reason.
  """
  def close_thread(thread_id, agent_id, reason \\ nil) do
    with {:ok, thread} <- get_thread(thread_id) do
      now = DateTime.utc_now()

      thread
      |> MessageThread.changeset(%{
        status: "closed",
        closed_at: now,
        closed_by: agent_id,
        close_reason: reason
      })
      |> Repo.update()
      |> tap(fn
        {:ok, _} ->
          Phoenix.PubSub.broadcast(
            @pubsub,
            "thread:#{thread_id}",
            {:thread_closed, %{thread_id: thread_id, closed_by: agent_id, reason: reason}}
          )
        _ -> :ok
      end)
    end
  end

  @doc """
  Add an agent as participant to a thread.
  """
  def add_participant(thread_id, agent_id) do
    with {:ok, thread} <- get_thread(thread_id) do
      if agent_id in thread.participant_ids do
        {:ok, thread}
      else
        updated_ids = thread.participant_ids ++ [agent_id]

        thread
        |> MessageThread.changeset(%{participant_ids: updated_ids})
        |> Repo.update()
      end
    end
  end

  @doc """
  Remove an agent from a thread's participants.
  """
  def remove_participant(thread_id, agent_id) do
    with {:ok, thread} <- get_thread(thread_id) do
      updated_ids = List.delete(thread.participant_ids, agent_id)

      thread
      |> MessageThread.changeset(%{participant_ids: updated_ids})
      |> Repo.update()
    end
  end

  # ════════════════════════════════════════════════════════════
  # Task Thread Integration
  # ════════════════════════════════════════════════════════════

  @doc """
  Find an existing thread for a kanban task, or create one.

  If a thread already exists for this task_id, returns it.
  Otherwise creates a new thread with scope "task" and subject
  derived from the task title.
  """
  def find_or_create_task_thread(fleet_id, task_id, creator_agent_id) do
    case Repo.one(
      from(t in MessageThread,
        where: t.fleet_id == ^fleet_id and t.task_id == ^task_id and t.status == "open",
        limit: 1
      )
    ) do
      %MessageThread{} = thread ->
        {:ok, thread}

      nil ->
        # Get task title from Kanban
        subject =
          case Hub.Kanban.get_task(task_id) do
            {:ok, task} -> "Task: #{task.title}"
            _ -> "Task: #{task_id}"
          end

        # Determine tenant_id from fleet
        tenant_id = get_fleet_tenant_id(fleet_id)

        create_thread(%{
          subject: subject,
          scope: "task",
          task_id: task_id,
          fleet_id: fleet_id,
          tenant_id: tenant_id,
          created_by: creator_agent_id,
          participant_ids: [creator_agent_id]
        })
    end
  end

  @doc """
  Close all open threads linked to a task. Called when a kanban task
  moves to "done".
  """
  def close_task_threads(task_id) do
    threads =
      from(t in MessageThread,
        where: t.task_id == ^task_id and t.status == "open"
      )
      |> Repo.all()

    Enum.each(threads, fn thread ->
      close_thread(thread.thread_id, "system", "task completed")
    end)

    :ok
  end

  # ════════════════════════════════════════════════════════════
  # Serialization
  # ════════════════════════════════════════════════════════════

  @doc """
  Convert a thread struct to a wire-format map for JSON responses.
  """
  def thread_to_wire(%MessageThread{} = thread) do
    %{
      "thread_id" => thread.thread_id,
      "subject" => thread.subject,
      "scope" => thread.scope,
      "status" => thread.status,
      "participant_ids" => thread.participant_ids,
      "task_id" => thread.task_id,
      "message_count" => thread.message_count,
      "last_message_at" => thread.last_message_at && DateTime.to_iso8601(thread.last_message_at),
      "created_by" => thread.created_by,
      "metadata" => thread.metadata,
      "created_at" => thread.inserted_at && NaiveDateTime.to_iso8601(thread.inserted_at),
      "closed_at" => thread.closed_at && DateTime.to_iso8601(thread.closed_at),
      "closed_by" => thread.closed_by,
      "close_reason" => thread.close_reason
    }
  end

  # ════════════════════════════════════════════════════════════
  # Private Helpers
  # ════════════════════════════════════════════════════════════

  defp base62_random(length) do
    for _ <- 1..length, into: "" do
      <<Enum.random(@base62)>>
    end
  end

  defp ensure_creator_is_participant(attrs) do
    creator = attrs[:created_by] || attrs["created_by"]
    participants = attrs[:participant_ids] || attrs["participant_ids"] || []

    if creator && creator not in participants do
      Map.put(attrs, :participant_ids, [creator | participants])
    else
      attrs
    end
  end

  defp fetch_message(store_key) do
    case StorePort.get_document(store_key) do
      {:ok, %{meta: meta}} when byte_size(meta) > 0 ->
        Jason.decode!(meta)

      _ ->
        nil
    end
  end

  defp maybe_filter_before(keys, nil, _prefix), do: keys
  defp maybe_filter_before(keys, before_ts, prefix) do
    Enum.filter(keys, fn key ->
      # key format: "thr_msg:{thread_id}:{timestamp}:{message_id}"
      # Extract timestamp portion
      case String.replace_prefix(key, prefix, "") do
        rest ->
          ts = rest |> String.split(":") |> List.first()
          ts && ts < before_ts
      end
    end)
  end

  defp get_fleet_tenant_id(fleet_id) do
    case Hub.Repo.get(Hub.Auth.Fleet, fleet_id) do
      %{tenant_id: tid} -> tid
      _ -> nil
    end
  end
end
