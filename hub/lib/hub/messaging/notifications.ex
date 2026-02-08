defmodule Hub.Messaging.Notifications do
  @moduledoc """
  Central notification system. Aggregates events from all messaging subsystems
  and delivers them to agents via their preferred channels.

  Notification types:
  - :dm_received — new direct message
  - :thread_reply — reply in a thread you're part of
  - :escalation_assigned — you've been assigned an escalation
  - :escalation_resolved — an escalation you created was resolved
  - :task_assigned — new kanban task assigned
  - :task_mentioned — you were mentioned in a task
  - :artifact_review — artifact needs your review
  - :artifact_reviewed — your artifact was reviewed
  - :announcement — fleet/squad announcement
  - :role_changed — your role was changed
  """

  require Logger

  alias Hub.StorePort

  @pubsub Hub.PubSub
  @max_notifications 100

  # ── Send a notification ────────────────────────────────────

  @doc """
  Send a notification to an agent. Stores it in StorePort and pushes
  via PubSub if the agent is online.

  ## Parameters
  - `fleet_id` — the fleet scope
  - `agent_id` — target agent to notify
  - `type` — notification type atom (e.g. :dm_received, :thread_reply)
  - `payload` — map with notification details

  Returns `{:ok, notification}`.
  """
  @spec notify(String.t(), String.t(), atom(), map()) :: {:ok, map()}
  def notify(fleet_id, agent_id, type, payload) do
    notification = %{
      "id" => "ntf_" <> gen_id(),
      "type" => to_string(type),
      "payload" => payload,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "read" => false
    }

    # Store notification
    store_notification(fleet_id, agent_id, notification)

    # Push to agent if online
    Phoenix.PubSub.broadcast(
      @pubsub,
      "fleet:#{fleet_id}:agent:#{agent_id}",
      {:notification, notification}
    )

    {:ok, notification}
  end

  # ── Unread count ───────────────────────────────────────────

  @doc "Get unread notification count for an agent."
  @spec unread_count(String.t(), String.t()) :: non_neg_integer()
  def unread_count(fleet_id, agent_id) do
    key = notifications_key(fleet_id, agent_id)

    case StorePort.get_document(key) do
      {:ok, %{meta: meta}} when byte_size(meta) > 0 ->
        case Jason.decode(meta) do
          {:ok, list} when is_list(list) ->
            Enum.count(list, fn n -> n["read"] == false end)

          _ ->
            0
        end

      _ ->
        0
    end
  end

  # ── List notifications ─────────────────────────────────────

  @doc """
  List recent notifications for an agent.

  ## Options
  - `:limit` — max notifications to return (default 20)
  - `:unread_only` — only return unread notifications (default false)
  """
  @spec list(String.t(), String.t(), keyword()) :: [map()]
  def list(fleet_id, agent_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    unread_only = Keyword.get(opts, :unread_only, false)
    key = notifications_key(fleet_id, agent_id)

    case StorePort.get_document(key) do
      {:ok, %{meta: meta}} when byte_size(meta) > 0 ->
        case Jason.decode(meta) do
          {:ok, list} when is_list(list) ->
            list
            |> maybe_filter_unread(unread_only)
            |> Enum.take(limit)

          _ ->
            []
        end

      _ ->
        []
    end
  end

  # ── Mark notification as read ──────────────────────────────

  @doc "Mark a specific notification as read."
  @spec mark_read(String.t(), String.t(), String.t()) :: :ok
  def mark_read(fleet_id, agent_id, notification_id) do
    key = notifications_key(fleet_id, agent_id)

    case StorePort.get_document(key) do
      {:ok, %{meta: meta}} when byte_size(meta) > 0 ->
        case Jason.decode(meta) do
          {:ok, list} when is_list(list) ->
            updated =
              Enum.map(list, fn n ->
                if n["id"] == notification_id do
                  Map.put(n, "read", true)
                else
                  n
                end
              end)

            StorePort.put_document(key, Jason.encode!(updated))

          _ ->
            :ok
        end

      _ ->
        :ok
    end

    :ok
  end

  # ── Mark all as read ───────────────────────────────────────

  @doc "Mark all notifications as read for an agent."
  @spec mark_all_read(String.t(), String.t()) :: :ok
  def mark_all_read(fleet_id, agent_id) do
    key = notifications_key(fleet_id, agent_id)

    case StorePort.get_document(key) do
      {:ok, %{meta: meta}} when byte_size(meta) > 0 ->
        case Jason.decode(meta) do
          {:ok, list} when is_list(list) ->
            updated = Enum.map(list, &Map.put(&1, "read", true))
            StorePort.put_document(key, Jason.encode!(updated))

          _ ->
            :ok
        end

      _ ->
        :ok
    end

    :ok
  end

  # ── Private ────────────────────────────────────────────────

  defp notifications_key(fleet_id, agent_id) do
    "ntf:#{fleet_id}:#{agent_id}"
  end

  defp store_notification(fleet_id, agent_id, notification) do
    key = notifications_key(fleet_id, agent_id)

    existing =
      case StorePort.get_document(key) do
        {:ok, %{meta: meta}} when byte_size(meta) > 0 ->
          case Jason.decode(meta) do
            {:ok, list} when is_list(list) -> list
            _ -> []
          end

        _ ->
          []
      end

    # Prepend new notification, cap at max
    updated = [notification | existing] |> Enum.take(@max_notifications)

    case StorePort.put_document(key, Jason.encode!(updated)) do
      :ok -> :ok
      {:error, reason} ->
        Logger.warning("[Notifications] Failed to store notification: #{inspect(reason)}")
        :ok
    end
  end

  defp maybe_filter_unread(list, true), do: Enum.filter(list, fn n -> n["read"] == false end)
  defp maybe_filter_unread(list, _), do: list

  @base62 ~c"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

  defp gen_id do
    for _ <- 1..16, into: "" do
      <<Enum.random(@base62)>>
    end
  end
end
