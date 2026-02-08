defmodule Hub.ContextInjection do
  @moduledoc """
  Adaptive context injection engine.

  Determines how much context to inject into messages sent to agents
  based on their detected capability tier.

  ## Tiers

  - **Tier 1 (Smart):** Claude Opus, GPT-4, Sonnet 4 — system prompt on connect only.
    Trust the agent to maintain context across messages.
  - **Tier 2 (Mid):** Sonnet 3.5, GPT-4o-mini, Mistral Large — role reminder
    prepended to task assignments and important messages.
  - **Tier 3 (Weak):** Local models (Llama, Qwen, Phi, Gemma <13B) — full
    context injected with EVERY message. Structured output enforced.

  ## Detection

  Priority: agent.context_tier (explicit override) > role.context_injection_tier
  > auto-detection from framework + model name.
  """

  alias Hub.Roles

  require Logger

  # ── Tier Detection ──────────────────────────────────────────

  @tier1_models ~w(opus gpt-4-turbo gpt-4o sonnet-4 claude-4 gemini-ultra gemini-pro-1.5)
  @tier2_models ~w(sonnet-3.5 sonnet gpt-4o-mini gpt-3.5 mistral-large command-r claude-3 gemini-flash mixtral-8x22b)
  @tier3_indicators ~w(llama qwen phi gemma mistral-7b codellama deepseek-coder tinyllama orca vicuna)

  @doc """
  Detect the context injection tier for an agent.

  Returns "tier1", "tier2", or "tier3".
  """
  def detect_tier(agent) do
    # Explicit override on agent takes highest priority
    cond do
      agent.context_tier in ["tier1", "tier2", "tier3"] ->
        agent.context_tier

      true ->
        # Check role template override
        role_tier = get_role_tier(agent)

        if role_tier in ["tier1", "tier2", "tier3"] do
          role_tier
        else
          # Auto-detect from model/framework/capabilities
          auto_detect_tier(agent)
        end
    end
  end

  defp get_role_tier(agent) do
    case Roles.agent_role_context(agent.agent_id) do
      nil -> "auto"
      ctx -> ctx.injection_tier || "auto"
    end
  end

  defp auto_detect_tier(agent) do
    model = (agent.metadata["model"] || agent.name || "") |> String.downcase()
    framework = (agent.framework || "") |> String.downcase()
    _caps = agent.capabilities || []

    cond do
      # Tier 1: Known powerful models
      Enum.any?(@tier1_models, &String.contains?(model, &1)) ->
        "tier1"

      # Tier 1: OpenClaw/LangChain with no weak model indicator
      framework in ["openclaw", "langchain", "autogen", "crewai"] and
        not Enum.any?(@tier3_indicators, &String.contains?(model, &1)) ->
        "tier1"

      # Tier 2: Known mid-tier models
      Enum.any?(@tier2_models, &String.contains?(model, &1)) ->
        "tier2"

      # Tier 2: Known frameworks with unknown model
      framework in ["openclaw", "langchain", "autogen", "crewai"] ->
        "tier2"

      # Tier 3: Known weak/local models
      Enum.any?(@tier3_indicators, &String.contains?(model, &1)) ->
        "tier3"

      # Tier 3: Ollama framework
      framework in ["ollama", "localai", "llama.cpp", "text-generation-webui"] ->
        "tier3"

      # Tier 3: No framework info at all
      framework == "" and model == "" ->
        "tier3"

      # Default: Tier 2 (safe middle ground)
      true ->
        "tier2"
    end
  end

  # ── Message Wrapping ────────────────────────────────────────

  @doc """
  Wrap a message with appropriate context for the agent's tier.

  ## Options
  - `:message_type` - "task", "direct", "notification" (default: "direct")
  - `:squad_name` - agent's squad name for context
  - `:active_tasks` - list of agent's active task IDs
  """
  def wrap_message(agent, message, opts \\ []) do
    tier = detect_tier(agent)
    message_type = Keyword.get(opts, :message_type, "direct")
    role_context = Roles.agent_role_context(agent.agent_id)

    case tier do
      "tier1" -> wrap_tier1(message, message_type)
      "tier2" -> wrap_tier2(message, message_type, role_context, opts)
      "tier3" -> wrap_tier3(message, message_type, role_context, opts)
      _ -> wrap_tier2(message, message_type, role_context, opts)
    end
  end

  # Tier 1: Minimal wrapping, trust the agent
  defp wrap_tier1(message, _message_type) do
    message
  end

  # Tier 2: Add role reminder to tasks
  defp wrap_tier2(message, message_type, role_context, _opts) when message_type in ["task", "notification"] do
    case role_context do
      nil ->
        message

      ctx ->
        Map.put(message, "context", %{
          "role" => ctx.role_name,
          "key_constraints" => ctx.constraints,
          "capabilities" => ctx.capabilities
        })
    end
  end

  defp wrap_tier2(message, _message_type, _role_context, _opts), do: message

  # Tier 3: Full context on every message
  defp wrap_tier3(message, _message_type, role_context, opts) do
    context =
      case role_context do
        nil ->
          %{"note" => "No role assigned. Ask your squad leader for role assignment."}

        ctx ->
          base = %{
            "your_role" => ctx.role_name,
            "system_prompt" => ctx.system_prompt,
            "capabilities" => ctx.capabilities,
            "constraints" => ctx.constraints,
            "tools_allowed" => ctx.tools_allowed,
            "escalation_rules" => ctx.escalation_rules
          }

          base =
            if squad = Keyword.get(opts, :squad_name) do
              Map.put(base, "your_squad", squad)
            else
              base
            end

          base =
            if tasks = Keyword.get(opts, :active_tasks) do
              Map.put(base, "your_active_tasks", tasks)
            else
              base
            end

          base =
            if ctx.respond_format do
              base
              |> Map.put("respond_format", ctx.respond_format)
              |> Map.put("respond_schema", ctx.respond_schema)
            else
              base
            end

          base
      end

    Map.put(message, "context", context)
  end

  # ── Role Context Building ──────────────────────────────────

  @doc """
  Build the full role context block for an agent.
  Used in join replies and role:context requests.
  """
  def build_role_context(agent) do
    case Roles.agent_role_context(agent.agent_id) do
      nil ->
        nil

      ctx ->
        %{
          "role" => %{
            "slug" => ctx.role_slug,
            "name" => ctx.role_name,
            "system_prompt" => ctx.system_prompt,
            "capabilities" => ctx.capabilities,
            "constraints" => ctx.constraints,
            "tools_allowed" => ctx.tools_allowed,
            "escalation_rules" => ctx.escalation_rules
          },
          "injection_tier" => detect_tier(agent),
          "respond_format" => ctx.respond_format,
          "respond_schema" => ctx.respond_schema
        }
    end
  end

  # ── Calibration ─────────────────────────────────────────────

  @doc """
  Generate a calibration challenge to probe an agent's capability tier.

  The challenge tests:
  1. Instruction following (can it respond in exact format?)
  2. Context retention (does it reference prior context?)
  3. Reasoning depth (can it solve a simple logic puzzle?)
  """
  def calibration_challenge do
    %{
      "type" => "calibration",
      "instructions" => """
      Respond with EXACTLY this JSON format (no markdown, no explanation):
      {"tier_response": {"format_test": "EXACT_MATCH", "reasoning": "<your answer>", "context_check": "<repeat the type field value>"}}

      Reasoning question: If agent A can complete 3 tasks/hour and agent B can complete 5 tasks/hour,
      how many tasks can they complete together in 2.5 hours?
      """,
      "expected_format" => "json",
      "challenge_id" => "cal_#{:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)}"
    }
  end

  @doc """
  Evaluate a calibration response and return a tier.

  Scoring:
  - Format correct (valid JSON, exact structure): +3 points
  - Reasoning correct (20 tasks): +3 points
  - Context check correct (references "calibration"): +2 points
  - Response time < 5s: +1 point
  - Response time < 2s: +1 point (bonus)

  Tier mapping:
  - 7-10 points: tier1
  - 4-6 points: tier2
  - 0-3 points: tier3
  """
  def evaluate_calibration(response, _opts \\ []) do
    score = 0

    # Try to parse as JSON
    {parsed, score} =
      case Jason.decode(response) do
        {:ok, %{"tier_response" => inner}} when is_map(inner) ->
          {inner, score + 3}

        {:ok, data} when is_map(data) ->
          {data, score + 1}

        _ ->
          {%{}, score}
      end

    # Check format_test
    score =
      if Map.get(parsed, "format_test") == "EXACT_MATCH" do
        score + 1
      else
        score
      end

    # Check reasoning (answer should be 20)
    score =
      case Map.get(parsed, "reasoning", "") do
        r when is_binary(r) ->
          if String.contains?(r, "20"), do: score + 3, else: score

        _ ->
          score
      end

    # Check context
    score =
      case Map.get(parsed, "context_check", "") do
        c when is_binary(c) ->
          if String.contains?(String.downcase(c), "calibration"), do: score + 2, else: score

        _ ->
          score
      end

    # Determine tier
    tier =
      cond do
        score >= 7 -> "tier1"
        score >= 4 -> "tier2"
        true -> "tier3"
      end

    %{tier: tier, score: score, max_score: 10}
  end

  # ── Identity Reinforcement ─────────────────────────────────

  @doc """
  Generate an identity reinforcement message for weak agents.
  Called periodically or before important tasks.
  """
  def identity_reinforcement(agent) do
    case Roles.agent_role_context(agent.agent_id) do
      nil ->
        nil

      ctx ->
        %{
          "type" => "identity_reinforcement",
          "message" => """
          REMINDER — You are #{ctx.role_name} in this fleet.

          Your core responsibilities: #{Enum.join(ctx.capabilities, ", ")}
          Your constraints: #{Enum.join(ctx.constraints, "; ")}

          #{if ctx.escalation_rules, do: "Escalation: #{ctx.escalation_rules}", else: ""}

          Confirm your understanding by stating your role and current task.
          """,
          "role" => ctx.role_slug,
          "requires_confirmation" => true
        }
    end
  end
end
