defmodule Hub.Messaging.Announcements do
  @moduledoc """
  One-way announcement messages. No reply expected.

  Broadcast to fleet, squad, or agents with a specific role.
  Only Tier 0-1 agents can send announcements.

  Announcements are stored in StorePort for history with key format:
  "ann:{fleet_id}:{timestamp}:{id}"
  """

  require Logger

  import Ecto.Query
  alias Hub.Repo
  alias Hub.StorePort
  alias Hub.Auth.Agent
  alias Hub.ContextInjection

  @pubsub Hub.PubSub
  @base62 ~c"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

  @doc """
  Send an announcement from an agent to a target scope.

  ## Parameters
  - `fleet_id` - the fleet to announce within
  - `from_agent_id` - sender agent_id (must be tier 0 or tier 1)
  - `scope` - target scope:
    - `"fleet"` — broadcast to entire fleet
    - `"squad:{squad_id}"` — broadcast to specific squad
    - `"role:{role_slug}"` — broadcast to all agents with this role
  - `attrs` - map with:
    - `:body` (required) — announcement text
    - `:priority` — "normal" | "high" | "urgent" (default "normal")
    - `:metadata` — additional metadata map

  Returns `{:ok, count}` (number of recipients) or `{:denied, reason}`.
  """
  def announce(fleet_id, from_agent_id, scope, attrs) when is_map(attrs) do
    # Verify sender has permission (tier 0 or 1)
    with {:ok, sender} <- get_sender(from_agent_id),
         :ok <- check_tier_permission(sender) do
      announcement_id = "ann_#{base62_random(12)}"
      now = DateTime.utc_now()
      timestamp = DateTime.to_iso8601(now)

      envelope = %{
        "id" => announcement_id,
        "type" => "announcement",
        "from" => from_agent_id,
        "fleet_id" => fleet_id,
        "scope" => scope,
        "body" => attrs[:body] || attrs["body"] || "",
        "priority" => attrs[:priority] || attrs["priority"] || "normal",
        "metadata" => attrs[:metadata] || attrs["metadata"] || %{},
        "timestamp" => timestamp
      }

      # Store for history
      store_key = "ann:#{fleet_id}:#{timestamp}:#{announcement_id}"
      json = Jason.encode!(envelope)

      case StorePort.put_document(store_key, json) do
        :ok -> :ok
        {:error, reason} ->
          Logger.warning("[Announcements] Failed to store announcement: #{inspect(reason)}")
      end

      # Broadcast based on scope
      count = broadcast_to_scope(fleet_id, scope, envelope)

      # Send notifications to all agents in scope
      Task.start(fn ->
        target_ids = resolve_notification_targets(fleet_id, from_agent_id, scope)

        Enum.each(target_ids, fn agent_id ->
          Hub.Messaging.Notifications.notify(fleet_id, agent_id, :announcement, %{
            "announcement_id" => announcement_id,
            "from" => from_agent_id,
            "scope" => scope,
            "preview" => String.slice(envelope["body"] || "", 0, 80),
            "priority" => envelope["priority"]
          })
        end)
      end)

      {:ok, count}
    end
  end

  @doc """
  Retrieve announcement history for a fleet.

  ## Options
  - `:limit` — max announcements to return (default 20)
  """
  def history(fleet_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    prefix = "ann:#{fleet_id}:"

    case StorePort.list_documents() do
      {:ok, ids} ->
        announcements =
          ids
          |> Enum.filter(&String.starts_with?(&1, prefix))
          |> Enum.sort()
          |> Enum.take(-limit)
          |> Enum.map(&fetch_announcement/1)
          |> Enum.reject(&is_nil/1)

        {:ok, announcements}

      {:error, _reason} ->
        {:ok, []}
    end
  end

  # ════════════════════════════════════════════════════════════
  # Private
  # ════════════════════════════════════════════════════════════

  defp get_sender(agent_id) do
    case Hub.Auth.find_agent(agent_id) do
      {:ok, agent} -> {:ok, agent}
      _ -> {:denied, "agent not found"}
    end
  end

  defp check_tier_permission(agent) do
    tier = ContextInjection.detect_tier(agent)

    if tier in ["tier1"] do
      :ok
    else
      # Also allow if the agent's context_tier is explicitly "tier0" or "tier1"
      if agent.context_tier in ["tier0", "tier1"] do
        :ok
      else
        {:denied, "only tier 0-1 agents can send announcements (detected: #{tier})"}
      end
    end
  end

  defp broadcast_to_scope(fleet_id, "fleet", envelope) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      "fleet:#{fleet_id}",
      {:announcement, envelope}
    )

    # Count approximate recipients from presence
    count_fleet_agents(fleet_id)
  end

  defp broadcast_to_scope(fleet_id, "squad:" <> squad_id, envelope) do
    # Broadcast on squad topic (agents subscribe to "squad:#{squad_id}")
    Phoenix.PubSub.broadcast(
      @pubsub,
      "squad:#{squad_id}",
      {:announcement, envelope}
    )

    # Also broadcast on fleet topic with scope marker (for dashboard/logging)
    Phoenix.PubSub.broadcast(
      @pubsub,
      "fleet:#{fleet_id}",
      {:announcement, Map.put(envelope, "target_squad", squad_id)}
    )

    count_squad_agents(squad_id)
  end

  defp broadcast_to_scope(fleet_id, "role:" <> role_slug, envelope) do
    # Find all agents with this role and broadcast to each
    agents = find_agents_by_role(fleet_id, role_slug)

    Enum.each(agents, fn agent ->
      Phoenix.PubSub.broadcast(
        @pubsub,
        "fleet:#{fleet_id}:agent:#{agent.agent_id}",
        {:announcement, envelope}
      )
    end)

    length(agents)
  end

  defp broadcast_to_scope(fleet_id, scope, envelope) do
    Logger.warning("[Announcements] Unknown scope: #{scope}, broadcasting to fleet")
    broadcast_to_scope(fleet_id, "fleet", envelope)
  end

  defp count_fleet_agents(fleet_id) do
    case Hub.FleetPresence.list("fleet:#{fleet_id}") do
      presences when is_map(presences) -> map_size(presences)
      _ -> 0
    end
  end

  defp count_squad_agents(squad_id) do
    from(a in Agent,
      where: a.squad_id == ^squad_id,
      select: count(a.id)
    )
    |> Repo.one() || 0
  end

  defp find_agents_by_role(fleet_id, role_slug) do
    # Find role template by slug
    role_template =
      from(r in Hub.Schemas.RoleTemplate,
        where: r.slug == ^role_slug,
        limit: 1
      )
      |> Repo.one()

    case role_template do
      nil ->
        []

      rt ->
        from(a in Agent,
          where: a.fleet_id == ^fleet_id and a.role_template_id == ^rt.id
        )
        |> Repo.all()
    end
  end

  defp fetch_announcement(store_key) do
    case StorePort.get_document(store_key) do
      {:ok, %{meta: meta}} when byte_size(meta) > 0 ->
        Jason.decode!(meta)

      _ ->
        nil
    end
  end

  # Resolve agent_ids for notification targets based on scope
  defp resolve_notification_targets(fleet_id, from_agent_id, "fleet") do
    from(a in Agent, where: a.fleet_id == ^fleet_id and a.agent_id != ^from_agent_id, select: a.agent_id)
    |> Repo.all()
  end

  defp resolve_notification_targets(_fleet_id, from_agent_id, "squad:" <> squad_id) do
    from(a in Agent, where: a.squad_id == ^squad_id and a.agent_id != ^from_agent_id, select: a.agent_id)
    |> Repo.all()
  end

  defp resolve_notification_targets(fleet_id, from_agent_id, "role:" <> role_slug) do
    find_agents_by_role(fleet_id, role_slug)
    |> Enum.map(& &1.agent_id)
    |> Enum.reject(&(&1 == from_agent_id))
  end

  defp resolve_notification_targets(fleet_id, from_agent_id, _scope) do
    resolve_notification_targets(fleet_id, from_agent_id, "fleet")
  end

  defp base62_random(length) do
    for _ <- 1..length, into: "" do
      <<Enum.random(@base62)>>
    end
  end
end
