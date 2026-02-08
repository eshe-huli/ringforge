defmodule Hub.Messaging.Escalation do
  @moduledoc """
  Escalation system: agents escalate messages up through hierarchy.

  Flow:
  1. Agent sends escalation with target_role and body
  2. System routes to agent's squad leader
  3. Squad leader can: forward / handle / reject / auto-forward
  4. If no squad leader → goes to fleet's tier-1 agents

  Escalations are stored in StorePort (Rust store) with key format
  `esc:{fleet_id}:{escalation_id}`.

  An index key `esc_idx:{fleet_id}` holds the list of all escalation IDs
  for prefix-free lookups.
  """

  require Logger

  alias Hub.StorePort
  alias Hub.Auth.Agent
  alias Hub.Schemas.RoleTemplate
  alias Hub.Messaging.AccessControl

  import Ecto.Query
  alias Hub.Repo

  @pubsub Hub.PubSub


  @base62 ~c"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

  # ── Escalation struct ──────────────────────────────────────

  defstruct [
    :id,
    :fleet_id,
    :from_agent,
    :target_role,
    :subject,
    :body,
    :priority,
    :context_refs,
    :status,
    :handler_agent,
    :forwarded_to,
    :response,
    :created_at,
    :updated_at
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          fleet_id: String.t(),
          from_agent: String.t(),
          target_role: String.t(),
          subject: String.t() | nil,
          body: String.t() | map(),
          priority: String.t(),
          context_refs: [String.t()],
          status: String.t(),
          handler_agent: String.t() | nil,
          forwarded_to: String.t() | nil,
          response: String.t() | map() | nil,
          created_at: String.t(),
          updated_at: String.t()
        }

  # ── Create ─────────────────────────────────────────────────

  @doc """
  Creates an escalation from `from_agent` in `fleet_id`, targeting `target_role`.

  Attrs should include:
  - `:subject` — short description (optional)
  - `:body` — the message content
  - `:priority` — "low", "normal", "high", "critical" (default: "normal")
  - `:context_refs` — list of related IDs (task IDs, message IDs, etc.)

  Routes to the agent's squad leader. If no squad leader exists,
  routes to fleet's tier-1 agents.

  Returns `{:ok, escalation}` or `{:error, reason}`.
  """
  @spec create_escalation(String.t(), String.t(), String.t(), map()) ::
          {:ok, t()} | {:error, String.t()}
  def create_escalation(fleet_id, from_agent_id, target_role, attrs) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    esc_id = "esc_#{base62_random(16)}"

    escalation = %__MODULE__{
      id: esc_id,
      fleet_id: fleet_id,
      from_agent: from_agent_id,
      target_role: target_role,
      subject: Map.get(attrs, :subject),
      body: Map.get(attrs, :body, ""),
      priority: Map.get(attrs, :priority, "normal"),
      context_refs: Map.get(attrs, :context_refs, []),
      status: "pending",
      handler_agent: nil,
      forwarded_to: nil,
      response: nil,
      created_at: now,
      updated_at: now
    }

    # Persist to StorePort
    store_key = "esc:#{fleet_id}:#{esc_id}"

    case StorePort.put_document(store_key, Jason.encode!(to_map(escalation)), <<>>) do
      :ok ->
        # Add to index
        add_to_index(fleet_id, esc_id)

        # Route to handler(s)
        notify_handlers(escalation)

        {:ok, escalation}

      {:error, reason} ->
        Logger.error("[Escalation] Failed to store escalation: #{inspect(reason)}")
        {:error, "Failed to store escalation"}
    end
  end

  # ── List pending for a handler ─────────────────────────────

  @doc """
  Lists escalations pending for a specific handler agent.

  Finds escalations where:
  - handler_agent matches, OR
  - agent is a squad leader and the escalation is from their squad, OR
  - agent is tier 1+ and no squad leader exists for the escalation's source
  """
  @spec list_pending(String.t(), String.t()) :: [t()]
  def list_pending(fleet_id, handler_agent_id) do
    all_escalations(fleet_id)
    |> Enum.filter(fn esc ->
      esc.status == "pending" and is_handler?(esc, handler_agent_id, fleet_id)
    end)
    |> Enum.sort_by(& &1.created_at, :desc)
  end

  # ── Forward ────────────────────────────────────────────────

  @doc """
  Forwards an escalation to a different agent.
  Only the current handler can forward.
  """
  @spec forward_escalation(String.t(), String.t(), String.t()) ::
          :ok | {:error, String.t()}
  def forward_escalation(escalation_id, handler_agent_id, to_agent_id) do
    with {:ok, esc} <- get_escalation_by_id(escalation_id),
         :ok <- verify_handler(esc, handler_agent_id) do
      updated = %{
        esc
        | status: "forwarded",
          handler_agent: handler_agent_id,
          forwarded_to: to_agent_id,
          updated_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      persist_escalation(updated)

      # Create a new pending escalation for the forwarded-to agent
      forwarded_esc = %{
        updated
        | id: "esc_#{base62_random(16)}",
          status: "pending",
          handler_agent: to_agent_id,
          forwarded_to: nil
      }

      persist_escalation(forwarded_esc)
      add_to_index(esc.fleet_id, forwarded_esc.id)

      # Notify the forwarded-to agent
      notify_agent(esc.fleet_id, to_agent_id, {:escalation_forwarded, to_map(forwarded_esc)})

      :ok
    end
  end

  # ── Handle ─────────────────────────────────────────────────

  @doc """
  Marks an escalation as handled with a response.
  """
  @spec handle_escalation(String.t(), String.t(), String.t() | map()) ::
          :ok | {:error, String.t()}
  def handle_escalation(escalation_id, handler_agent_id, response) do
    with {:ok, esc} <- get_escalation_by_id(escalation_id),
         :ok <- verify_handler(esc, handler_agent_id) do
      updated = %{
        esc
        | status: "handled",
          handler_agent: handler_agent_id,
          response: response,
          updated_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      persist_escalation(updated)

      # Notify the originator
      notify_agent(esc.fleet_id, esc.from_agent, {:escalation_handled, to_map(updated)})

      :ok
    end
  end

  # ── Reject ─────────────────────────────────────────────────

  @doc """
  Rejects an escalation with a reason.
  """
  @spec reject_escalation(String.t(), String.t(), String.t()) ::
          :ok | {:error, String.t()}
  def reject_escalation(escalation_id, handler_agent_id, reason) do
    with {:ok, esc} <- get_escalation_by_id(escalation_id),
         :ok <- verify_handler(esc, handler_agent_id) do
      updated = %{
        esc
        | status: "rejected",
          handler_agent: handler_agent_id,
          response: %{"rejection_reason" => reason},
          updated_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      persist_escalation(updated)

      # Notify the originator
      notify_agent(esc.fleet_id, esc.from_agent, {:escalation_rejected, to_map(updated)})

      :ok
    end
  end

  # ── Auto-forward rules ────────────────────────────────────

  @doc """
  Returns auto-forward rules for a fleet. Loaded from StorePort.

  Rules format:
  ```
  [%{from_role: "backend-dev", target_role: "tech-lead", auto_forward: true},
   %{priority: "critical", auto_forward: true, target: :tier1}]
  ```
  """
  @spec auto_forward_rules(String.t()) :: [map()]
  def auto_forward_rules(fleet_id) do
    key = "esc_rules:#{fleet_id}"

    case StorePort.get_document(key) do
      {:ok, %{meta: meta}} when byte_size(meta) > 0 ->
        case Jason.decode(meta) do
          {:ok, rules} -> rules
          _ -> default_auto_forward_rules()
        end

      _ ->
        default_auto_forward_rules()
    end
  end

  # ── Private ────────────────────────────────────────────────

  defp default_auto_forward_rules do
    [
      %{"priority" => "critical", "auto_forward" => true, "target" => "tier1"},
      %{"from_role" => "backend-dev", "target_role" => "squad-leader", "auto_forward" => false},
      %{"from_role" => "frontend-dev", "target_role" => "squad-leader", "auto_forward" => false}
    ]
  end

  defp notify_handlers(%__MODULE__{} = esc) do
    # 1. Try to find the agent's squad leader
    handler_ids = find_handler_ids(esc)

    Enum.each(handler_ids, fn handler_id ->
      notify_agent(esc.fleet_id, handler_id, {:escalation_new, to_map(esc)})
    end)

    # Check auto-forward rules for critical priority
    rules = auto_forward_rules(esc.fleet_id)

    Enum.each(rules, fn rule ->
      if rule["auto_forward"] == true and matches_rule?(esc, rule) do
        tier1_agents = fleet_tier1_agent_ids(esc.fleet_id)

        Enum.each(tier1_agents, fn agent_id ->
          unless agent_id in handler_ids do
            notify_agent(esc.fleet_id, agent_id, {:escalation_auto_forwarded, to_map(esc)})
          end
        end)
      end
    end)
  end

  defp matches_rule?(esc, rule) do
    cond do
      rule["priority"] && esc.priority == rule["priority"] -> true
      rule["from_role"] && esc.target_role == rule["from_role"] -> true
      true -> false
    end
  end

  defp find_handler_ids(%__MODULE__{} = esc) do
    # First, try the sender's squad leader
    case find_squad_leader_for_agent(esc.from_agent) do
      nil ->
        # No squad leader → send to fleet's tier-1 agents
        fleet_tier1_agent_ids(esc.fleet_id)

      leader_id ->
        [leader_id]
    end
  end

  defp find_squad_leader_for_agent(agent_id) do
    case Hub.Auth.find_agent(agent_id) do
      {:ok, %Agent{squad_id: nil}} ->
        nil

      {:ok, %Agent{squad_id: squad_id}} ->
        case Repo.one(
               from(a in Agent,
                 join: r in RoleTemplate,
                 on: a.role_template_id == r.id,
                 where: a.squad_id == ^squad_id and r.slug == "squad-leader",
                 select: a.agent_id,
                 limit: 1
               )
             ) do
          nil -> nil
          agent_id -> agent_id
        end

      _ ->
        nil
    end
  end

  defp fleet_tier1_agent_ids(fleet_id) do
    tier1_slugs = ~w(tech-lead product-manager consultant)

    from(a in Agent,
      join: r in RoleTemplate,
      on: a.role_template_id == r.id,
      where: a.fleet_id == ^fleet_id and r.slug in ^tier1_slugs,
      select: a.agent_id
    )
    |> Repo.all()
  end

  defp is_handler?(esc, agent_id, fleet_id) do
    cond do
      # Explicitly assigned handler
      esc.handler_agent == agent_id ->
        true

      # Agent is the squad leader of the escalation sender
      find_squad_leader_for_agent(esc.from_agent) == agent_id ->
        true

      # Agent is tier 1+ and no squad leader exists
      find_squad_leader_for_agent(esc.from_agent) == nil ->
        agent = Repo.one(from(a in Agent, where: a.agent_id == ^agent_id and a.fleet_id == ^fleet_id))

        if agent do
          agent = Repo.preload(agent, :role_template)
          AccessControl.agent_tier(agent) <= 1
        else
          false
        end

      true ->
        false
    end
  end

  defp verify_handler(esc, agent_id) do
    if is_handler?(esc, agent_id, esc.fleet_id) do
      :ok
    else
      {:error, "You are not authorized to handle this escalation"}
    end
  end

  defp get_escalation_by_id(escalation_id) do
    # We need to search across all fleets — extract fleet from the ID if possible
    # Or search through all known escalations
    # The escalation_id embeds no fleet info, so we scan the index
    case StorePort.list_documents() do
      {:ok, ids} ->
        key =
          Enum.find(ids, fn id ->
            String.starts_with?(id, "esc:") and String.ends_with?(id, ":#{escalation_id}")
          end)

        if key do
          load_escalation(key)
        else
          {:error, "Escalation not found: #{escalation_id}"}
        end

      {:error, _} ->
        {:error, "Failed to look up escalation"}
    end
  end

  defp all_escalations(fleet_id) do
    index_key = "esc_idx:#{fleet_id}"

    esc_ids =
      case StorePort.get_document(index_key) do
        {:ok, %{meta: meta}} when byte_size(meta) > 0 ->
          case Jason.decode(meta) do
            {:ok, ids} when is_list(ids) -> ids
            _ -> []
          end

        _ ->
          []
      end

    esc_ids
    |> Enum.map(fn esc_id -> load_escalation("esc:#{fleet_id}:#{esc_id}") end)
    |> Enum.filter(fn
      {:ok, _} -> true
      _ -> false
    end)
    |> Enum.map(fn {:ok, esc} -> esc end)
  end

  defp load_escalation(store_key) do
    case StorePort.get_document(store_key) do
      {:ok, %{meta: meta}} when byte_size(meta) > 0 ->
        case Jason.decode(meta) do
          {:ok, data} -> {:ok, from_map(data)}
          _ -> {:error, "corrupt escalation data"}
        end

      _ ->
        {:error, "escalation not found"}
    end
  end

  defp persist_escalation(%__MODULE__{} = esc) do
    store_key = "esc:#{esc.fleet_id}:#{esc.id}"
    StorePort.put_document(store_key, Jason.encode!(to_map(esc)), <<>>)
  end

  defp add_to_index(fleet_id, esc_id) do
    index_key = "esc_idx:#{fleet_id}"

    existing =
      case StorePort.get_document(index_key) do
        {:ok, %{meta: meta}} when byte_size(meta) > 0 ->
          case Jason.decode(meta) do
            {:ok, ids} when is_list(ids) -> ids
            _ -> []
          end

        _ ->
          []
      end

    updated = [esc_id | existing] |> Enum.uniq()
    StorePort.put_document(index_key, Jason.encode!(updated), <<>>)
  end

  defp notify_agent(fleet_id, agent_id, message) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      "fleet:#{fleet_id}:agent:#{agent_id}",
      {:message, message}
    )
  end

  defp to_map(%__MODULE__{} = esc) do
    %{
      "id" => esc.id,
      "fleet_id" => esc.fleet_id,
      "from_agent" => esc.from_agent,
      "target_role" => esc.target_role,
      "subject" => esc.subject,
      "body" => esc.body,
      "priority" => esc.priority,
      "context_refs" => esc.context_refs,
      "status" => esc.status,
      "handler_agent" => esc.handler_agent,
      "forwarded_to" => esc.forwarded_to,
      "response" => esc.response,
      "created_at" => esc.created_at,
      "updated_at" => esc.updated_at
    }
  end

  defp from_map(data) when is_map(data) do
    %__MODULE__{
      id: data["id"],
      fleet_id: data["fleet_id"],
      from_agent: data["from_agent"],
      target_role: data["target_role"],
      subject: data["subject"],
      body: data["body"],
      priority: data["priority"] || "normal",
      context_refs: data["context_refs"] || [],
      status: data["status"] || "pending",
      handler_agent: data["handler_agent"],
      forwarded_to: data["forwarded_to"],
      response: data["response"],
      created_at: data["created_at"],
      updated_at: data["updated_at"]
    }
  end

  defp base62_random(length) do
    for _ <- 1..length, into: "" do
      <<Enum.random(@base62)>>
    end
  end
end
