defmodule Hub.Messaging.Router do
  @moduledoc """
  Central message router. All inter-agent messages flow through here.

  Pipeline: Validate → BusinessRules → AccessControl → RateLimit → Transform → Deliver

  Every message type (DM, broadcast, escalation, squad, thread reply) goes through
  a consistent pipeline that enforces access control, rate limiting, and context
  injection before delivery.
  """

  require Logger

  alias Hub.Messaging.{AccessControl, RateLimiter, Escalation, BusinessRules}
  alias Hub.ContextInjection
  alias Hub.Auth
  alias Hub.Auth.Agent
  alias Hub.Repo

  import Ecto.Query

  @pubsub Hub.PubSub

  # ── Route DM ───────────────────────────────────────────────

  @doc """
  Route a direct message from one agent to another.

  Pipeline:
  1. Load sender + target agents (with role_template)
  2. Evaluate business rules
  3. Check AccessControl.can_dm?
  4. Check RateLimiter
  5. Wrap message via ContextInjection
  6. Deliver via DirectMessage (PubSub + offline queue)

  Returns `{:ok, result}`, `{:denied, reason, suggestion}`, or `{:limited, retry_after_ms}`.
  """
  @spec route_dm(String.t(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:denied, String.t(), map()} | {:limited, non_neg_integer()}
  def route_dm(fleet_id, from_agent_id, to_agent_id, message) do
    with {:ok, sender} <- load_agent(from_agent_id),
         {:ok, target} <- load_agent(to_agent_id),
         :ok <- validate_same_fleet(sender, target, fleet_id),
         sender_tier <- AccessControl.agent_tier(sender),
         rules <- BusinessRules.load_rules(fleet_id),
         context <- build_rule_context(sender, target, fleet_id),
         :ok <- evaluate_business_rules(rules, :dm, context),
         :ok <- check_access_control_dm(sender, target, fleet_id, rules),
         :ok <- check_rate_limit(from_agent_id, :dm, sender_tier) do
      # Transform message based on target's tier
      wrapped = wrap_for_target(target, message)

      # Deliver
      result = Hub.DirectMessage.send_message(fleet_id, from_agent_id, to_agent_id, wrapped)

      # Record rate limit event on success
      case result do
        {:ok, _} -> RateLimiter.record(from_agent_id, :dm)
        _ -> :ok
      end

      result
    end
  end

  # ── Route Escalation ───────────────────────────────────────

  @doc """
  Route an escalation from an agent to a target role.

  Pipeline:
  1. Load sender agent
  2. Check AccessControl.can_escalate?
  3. Create escalation via Escalation module
  4. Notify handlers

  Returns `{:ok, escalation}` or `{:error, reason}`.
  """
  @spec route_escalation(String.t(), String.t(), String.t(), map()) ::
          {:ok, Escalation.t()} | {:error, String.t()} | {:denied, String.t()}
  def route_escalation(fleet_id, from_agent_id, target_role, message) do
    with {:ok, sender} <- load_agent(from_agent_id),
         :ok <- check_escalation_access(sender, target_role) do
      attrs = %{
        subject: Map.get(message, "subject") || Map.get(message, :subject),
        body: Map.get(message, "body") || Map.get(message, :body) || message,
        priority: Map.get(message, "priority") || Map.get(message, :priority, "normal"),
        context_refs: Map.get(message, "context_refs") || Map.get(message, :context_refs, [])
      }

      Escalation.create_escalation(fleet_id, from_agent_id, target_role, attrs)
    end
  end

  # ── Route Broadcast ────────────────────────────────────────

  @doc """
  Route a broadcast message to a scope (:fleet, :squad, {:squad, squad_id}).

  Pipeline:
  1. Load sender agent
  2. Business rules evaluation
  3. AccessControl.can_broadcast?
  4. RateLimiter check
  5. Fan out to all targets via PubSub

  Returns `{:ok, count}` (number of recipients) or `{:denied, reason}`.
  """
  @spec route_broadcast(String.t(), String.t(), atom() | tuple(), map()) ::
          {:ok, non_neg_integer()} | {:denied, String.t()} | {:limited, non_neg_integer()}
  def route_broadcast(fleet_id, from_agent_id, scope, message) do
    with {:ok, sender} <- load_agent(from_agent_id),
         sender_tier <- AccessControl.agent_tier(sender),
         rules <- BusinessRules.load_rules(fleet_id),
         :ok <- check_broadcast_access(sender, scope, rules),
         :ok <- check_rate_limit(from_agent_id, :broadcast, sender_tier) do
      # Determine target agent IDs based on scope
      target_ids = resolve_broadcast_targets(fleet_id, from_agent_id, scope)

      # Build broadcast envelope
      from_name = sender.display_name || sender.name || from_agent_id
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      envelope = %{
        "type" => "broadcast",
        "from" => %{"agent_id" => from_agent_id, "name" => from_name},
        "scope" => scope_to_string(scope),
        "message" => message,
        "timestamp" => now
      }

      # Fan out
      Enum.each(target_ids, fn target_id ->
        unless target_id == from_agent_id do
          Phoenix.PubSub.broadcast(
            @pubsub,
            "fleet:#{fleet_id}:agent:#{target_id}",
            {:broadcast_message, envelope}
          )
        end
      end)

      # Record rate
      RateLimiter.record(from_agent_id, :broadcast)

      # Persist to EventBus
      persist_broadcast(fleet_id, envelope)

      {:ok, length(target_ids) - 1}
    end
  end

  # ── Route Squad Message ────────────────────────────────────

  @doc """
  Route a message to all agents in a specific squad.

  This is a convenience wrapper — it checks the sender can message the squad,
  then broadcasts to the squad scope.
  """
  @spec route_squad_message(String.t(), String.t(), String.t(), map()) ::
          {:ok, non_neg_integer()} | {:denied, String.t()}
  def route_squad_message(fleet_id, from_agent_id, squad_id, message) do
    with {:ok, sender} <- load_agent(from_agent_id) do
      scope =
        if sender.squad_id == squad_id do
          :squad
        else
          {:squad, squad_id}
        end

      route_broadcast(fleet_id, from_agent_id, scope, message)
    end
  end

  # ── Route Thread Reply ─────────────────────────────────────

  @doc """
  Route a reply to an existing thread.

  Thread replies follow the same access control as DMs — the sender must
  be able to message the thread's original participants.

  Returns `{:ok, message_map}` or `{:denied, reason}`.
  """
  @spec route_thread_reply(String.t(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:denied, String.t()}
  def route_thread_reply(fleet_id, from_agent_id, thread_id, message) do
    with {:ok, sender} <- load_agent(from_agent_id),
         sender_tier <- AccessControl.agent_tier(sender),
         :ok <- check_rate_limit(from_agent_id, :dm, sender_tier) do
      from_name = sender.display_name || sender.name || from_agent_id
      now = DateTime.utc_now() |> DateTime.to_iso8601()
      msg_id = "msg_#{base62_random(16)}"

      reply = %{
        "message_id" => msg_id,
        "thread_id" => thread_id,
        "from" => %{"agent_id" => from_agent_id, "name" => from_name},
        "message" => message,
        "timestamp" => now
      }

      # Broadcast to the thread topic
      Phoenix.PubSub.broadcast(
        @pubsub,
        "fleet:#{fleet_id}:thread:#{thread_id}",
        {:thread_reply, reply}
      )

      RateLimiter.record(from_agent_id, :dm)

      {:ok, reply}
    end
  end

  # ── Private: Agent Loading ─────────────────────────────────

  defp load_agent(agent_id) do
    case Repo.get_by(Agent, agent_id: agent_id) do
      nil ->
        {:error, "Agent not found: #{agent_id}"}

      agent ->
        {:ok, Repo.preload(agent, :role_template)}
    end
  end

  defp validate_same_fleet(sender, target, fleet_id) do
    sender_fleet = sender.fleet_id
    target_fleet = target.fleet_id

    if sender_fleet == fleet_id and target_fleet == fleet_id do
      :ok
    else
      {:denied, "Agents must be in the same fleet",
       %{
         suggestion: "Verify the target agent is in your fleet",
         sender_fleet: sender_fleet,
         target_fleet: target_fleet
       }}
    end
  end

  # ── Private: Business Rules ────────────────────────────────

  defp build_rule_context(sender, target, fleet_id) do
    sender_tier = AccessControl.agent_tier(sender)
    target_tier = AccessControl.agent_tier(target)

    %{
      sender_tier: sender_tier,
      target_tier: target_tier,
      cross_squad: !same_squad?(sender, target),
      priority: nil,
      sender_has_active_task: has_active_task?(sender.agent_id, fleet_id)
    }
  end

  defp evaluate_business_rules(rules, action, context) do
    case BusinessRules.evaluate(rules, action, context) do
      :allow -> :ok
      {:deny, reason} -> {:denied, reason, %{source: :business_rules}}
      {:transform, _transforms} -> :ok
    end
  end

  # ── Private: Access Control ────────────────────────────────

  defp check_access_control_dm(sender, target, fleet_id, rules) do
    case AccessControl.can_dm?(sender, target, fleet_id, rules) do
      :ok -> :ok
      {:denied, reason, suggestion} -> {:denied, reason, suggestion}
    end
  end

  defp check_broadcast_access(sender, scope, rules) do
    case AccessControl.can_broadcast?(sender, scope, rules) do
      :ok -> :ok
      {:denied, reason} -> {:denied, reason}
    end
  end

  defp check_escalation_access(sender, target_role) do
    case AccessControl.can_escalate?(sender, target_role) do
      :ok -> :ok
      {:denied, reason} -> {:denied, reason}
    end
  end

  # ── Private: Rate Limiting ─────────────────────────────────

  defp check_rate_limit(agent_id, action_type, tier) do
    case RateLimiter.check_rate(agent_id, action_type, tier) do
      :ok -> :ok
      {:limited, retry_after} -> {:limited, retry_after}
    end
  end

  # ── Private: Message Transformation ────────────────────────

  defp wrap_for_target(target, message) do
    Hub.Messaging.Transform.format_for_target(message, target)
  end

  # ── Private: Broadcast Targets ─────────────────────────────

  defp resolve_broadcast_targets(fleet_id, _from_agent_id, :fleet) do
    from(a in Agent, where: a.fleet_id == ^fleet_id, select: a.agent_id)
    |> Repo.all()
  end

  defp resolve_broadcast_targets(fleet_id, from_agent_id, :squad) do
    case Repo.get_by(Agent, agent_id: from_agent_id) do
      %Agent{squad_id: nil} -> []
      %Agent{squad_id: squad_id} -> resolve_broadcast_targets(fleet_id, from_agent_id, {:squad, squad_id})
      nil -> []
    end
  end

  defp resolve_broadcast_targets(_fleet_id, _from_agent_id, {:squad, squad_id}) do
    from(a in Agent, where: a.squad_id == ^squad_id, select: a.agent_id)
    |> Repo.all()
  end

  defp resolve_broadcast_targets(_fleet_id, _from_agent_id, _scope), do: []

  # ── Private: Helpers ───────────────────────────────────────

  defp same_squad?(%Agent{squad_id: nil}, _target), do: false
  defp same_squad?(_sender, %Agent{squad_id: nil}), do: false
  defp same_squad?(%Agent{squad_id: s}, %Agent{squad_id: t}), do: s == t

  defp has_active_task?(agent_id, fleet_id) do
    # Check kanban for in-progress tasks assigned to this agent
    import Ecto.Query

    Repo.exists?(
      from(t in Hub.Schemas.KanbanTask,
        where: t.fleet_id == ^fleet_id and t.assigned_to == ^agent_id and t.lane == "in_progress"
      )
    )
  rescue
    _ -> false
  end

  defp scope_to_string(:fleet), do: "fleet"
  defp scope_to_string(:squad), do: "squad"
  defp scope_to_string({:squad, id}), do: "squad:#{id}"
  defp scope_to_string(other), do: to_string(other)

  defp persist_broadcast(fleet_id, envelope) do
    bus_topic = "ringforge.#{fleet_id}.broadcast"

    Task.start(fn ->
      case Hub.EventBus.publish(bus_topic, envelope) do
        :ok -> :ok
        {:error, reason} ->
          Logger.warning("[Router] EventBus broadcast persist failed: #{inspect(reason)}")
      end
    end)
  end

  @base62 ~c"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

  defp base62_random(length) do
    for _ <- 1..length, into: "" do
      <<Enum.random(@base62)>>
    end
  end
end
