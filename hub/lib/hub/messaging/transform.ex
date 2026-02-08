defmodule Hub.Messaging.Transform do
  @moduledoc """
  Message transformation engine.

  Transforms messages before delivery based on sender/target tiers:
  - Context injection (via ContextInjection module)
  - Auto-attach task context when sender has active task
  - Auto-summary for escalations from weak agents
  - Message batching for weak→strong agent communication
  """

  alias Hub.ContextInjection
  alias Hub.Kanban

  require Logger

  # ── Task ref patterns ──
  @task_ref_pattern ~r/T-\d{3,}/
  @code_ref_pattern ~r/(?:[a-zA-Z0-9_\-]+\.(?:ex|exs|py|js|ts|rs|go|rb|java|c|h|cpp|md|yaml|yml|json|toml))|(?:`[^`]+`)/

  # ════════════════════════════════════════════════════════════
  # Main Transform Pipeline
  # ════════════════════════════════════════════════════════════

  @doc """
  Transform a message through the full pipeline before delivery.

  Pipeline:
  1. Attach task context if sender has active kanban tasks
  2. Wrap with ContextInjection for target's tier
  3. Format response schema for tier-3 targets

  ## Parameters
  - `message` - map with at least "body" key
  - `sender_agent` - sender agent struct (with agent_id, fleet_id)
  - `target_agent` - target agent struct (with context_tier, role_template_id)

  Returns the transformed message map.
  """
  def transform(message, sender_agent, target_agent) when is_map(message) do
    message
    |> attach_task_context(sender_agent)
    |> wrap_for_tier(target_agent)
    |> format_for_target(target_agent)
  end

  # ════════════════════════════════════════════════════════════
  # Task Context Attachment
  # ════════════════════════════════════════════════════════════

  @doc """
  Attach active task context to a message.

  Queries Kanban.agent_queue for the sender's in-progress tasks and adds
  a `task_context` field with relevant task info.
  """
  def attach_task_context(message, sender_agent) do
    agent_id = sender_agent.agent_id
    fleet_id = get_fleet_id(sender_agent)

    if fleet_id do
      try do
        tasks = Kanban.agent_queue(agent_id, fleet_id)
        active = Enum.filter(tasks, fn t -> t.lane == "in_progress" end)

        if active != [] do
          task_context =
            Enum.map(active, fn t ->
              %{
                "task_id" => t.task_id,
                "title" => t.title,
                "priority" => t.priority,
                "progress" => t.progress,
                "progress_pct" => t.progress_pct
              }
            end)

          Map.put(message, "task_context", task_context)
        else
          message
        end
      rescue
        e ->
          Logger.warning("[Transform] Failed to attach task context: #{inspect(e)}")
          message
      end
    else
      message
    end
  end

  # ════════════════════════════════════════════════════════════
  # Escalation Summarization
  # ════════════════════════════════════════════════════════════

  @doc """
  Summarize a message body for escalation from weak agents.

  Pure text processing — no LLM call:
  - Takes first sentence
  - Extracts any T-XXX task references
  - Extracts any code/file references
  - Caps at 200 chars
  - Prepends "[Auto-summarized from N words]"
  """
  def summarize_for_escalation(body) when is_binary(body) do
    body = String.trim(body)
    word_count = body |> String.split(~r/\s+/) |> length()

    # If already short enough, don't summarize
    if word_count <= 30 do
      body
    else
      # Extract first sentence
      first_sentence =
        body
        |> String.split(~r/[.!?]\s+/, parts: 2)
        |> List.first()
        |> String.trim()
        |> String.slice(0, 150)

      # Extract task references
      task_refs =
        Regex.scan(@task_ref_pattern, body)
        |> List.flatten()
        |> Enum.uniq()

      # Extract code/file references
      code_refs =
        Regex.scan(@code_ref_pattern, body)
        |> List.flatten()
        |> Enum.uniq()
        |> Enum.take(5)

      # Build summary
      parts = [first_sentence]

      parts =
        if task_refs != [] do
          parts ++ ["Tasks: #{Enum.join(task_refs, ", ")}"]
        else
          parts
        end

      parts =
        if code_refs != [] do
          parts ++ ["Refs: #{Enum.join(code_refs, ", ")}"]
        else
          parts
        end

      summary =
        parts
        |> Enum.join(" | ")
        |> String.slice(0, 200)

      "[Auto-summarized from #{word_count} words] #{summary}"
    end
  end

  def summarize_for_escalation(_), do: ""

  # ════════════════════════════════════════════════════════════
  # Tier-based Formatting
  # ════════════════════════════════════════════════════════════

  @doc """
  Format a message for the target agent's tier.

  - Tier 1: minimal (just body + refs)
  - Tier 2: body + role reminder + refs
  - Tier 3: full context + body + response format + schema
  """
  def format_for_target(message, target_agent) do
    tier = detect_target_tier(target_agent)

    case tier do
      "tier1" -> format_tier1(message)
      "tier2" -> format_tier2(message, target_agent)
      "tier3" -> format_tier3(message, target_agent)
      _ -> format_tier2(message, target_agent)
    end
  end

  defp format_tier1(message) do
    # Minimal — just body + refs, strip heavy context
    message
    |> Map.take(["body", "refs", "id", "thread_id", "from", "timestamp", "task_context"])
  end

  defp format_tier2(message, target_agent) do
    # Add role reminder if target has one
    case get_role_name(target_agent) do
      nil ->
        message

      role_name ->
        Map.put(message, "role_reminder", "You are: #{role_name}")
    end
  end

  defp format_tier3(message, target_agent) do
    # Full context: wrap through ContextInjection
    message = format_tier2(message, target_agent)

    # Add response format hint for structured output
    message
    |> Map.put("response_format", %{
      "type" => "json",
      "schema" => %{
        "status" => "ok | error | need_help",
        "reply" => "your response text",
        "refs" => ["any task or file references"],
        "escalate" => "null or reason to escalate"
      }
    })
    |> Map.put("instructions", "Respond using the response_format schema above. Keep replies concise.")
  end

  # ════════════════════════════════════════════════════════════
  # Message Batching
  # ════════════════════════════════════════════════════════════

  @doc """
  Batch multiple messages from the same sender into one consolidated message.

  Takes a list of messages and consolidates into one message with numbered items.
  Used by the rate limiter when messages queue up.
  """
  def batch_messages([single]), do: single

  def batch_messages(messages) when is_list(messages) and length(messages) > 0 do
    first = hd(messages)

    # Consolidate bodies into numbered list
    consolidated_body =
      messages
      |> Enum.with_index(1)
      |> Enum.map(fn {msg, idx} ->
        body = msg["body"] || ""
        "#{idx}. #{body}"
      end)
      |> Enum.join("\n")

    # Merge all refs
    all_refs =
      messages
      |> Enum.flat_map(fn msg -> msg["refs"] || [] end)
      |> Enum.uniq()

    # Merge all task contexts
    all_task_contexts =
      messages
      |> Enum.flat_map(fn msg -> msg["task_context"] || [] end)
      |> Enum.uniq_by(fn tc -> tc["task_id"] end)

    # Merge metadata
    merged_metadata =
      messages
      |> Enum.reduce(%{}, fn msg, acc ->
        Map.merge(acc, msg["metadata"] || %{})
      end)

    result = %{
      "id" => "batch_#{:crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)}",
      "thread_id" => first["thread_id"],
      "from" => first["from"],
      "body" => "[Batched #{length(messages)} messages]\n#{consolidated_body}",
      "refs" => all_refs,
      "metadata" => Map.put(merged_metadata, "batched_count", length(messages)),
      "timestamp" => List.last(messages)["timestamp"] || DateTime.utc_now() |> DateTime.to_iso8601()
    }

    if all_task_contexts != [] do
      Map.put(result, "task_context", all_task_contexts)
    else
      result
    end
  end

  def batch_messages([]), do: nil

  # ════════════════════════════════════════════════════════════
  # Private Helpers
  # ════════════════════════════════════════════════════════════

  defp wrap_for_tier(message, target_agent) do
    try do
      ContextInjection.wrap_message(target_agent, message)
    rescue
      _ -> message
    end
  end

  defp detect_target_tier(agent) do
    try do
      ContextInjection.detect_tier(agent)
    rescue
      _ -> "tier2"
    end
  end

  defp get_role_name(agent) do
    try do
      case Hub.Roles.agent_role_context(agent.agent_id) do
        nil -> nil
        ctx -> ctx.role_name
      end
    rescue
      _ -> nil
    end
  end

  defp get_fleet_id(agent) do
    cond do
      is_map(agent) and Map.has_key?(agent, :fleet_id) -> agent.fleet_id
      is_map(agent) and Map.has_key?(agent, "fleet_id") -> agent["fleet_id"]
      true -> nil
    end
  end
end
