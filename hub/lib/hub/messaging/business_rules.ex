defmodule Hub.Messaging.BusinessRules do
  @moduledoc """
  Configurable business rules engine for message routing.
  Rules are stored per-fleet in StorePort.

  Default rules applied when no fleet-specific rules exist.

  ## Rule types

  - `:access` — allow/deny a message based on conditions
  - `:rate_limit` — override per-tier rate limits
  - `:transform` — transform message content before delivery

  ## Evaluation order

  Rules are evaluated in order. First matching `:access` rule with `action: :allow`
  short-circuits to allow. First matching `:access` rule with `action: :deny` blocks.
  If no access rule matches, the default is `:allow`.

  Rate limit rules override the tier defaults. Transform rules are accumulated
  and all matching transforms are applied.
  """

  require Logger
  alias Hub.StorePort

  @store_prefix "biz_rules"

  # ── Default rules ──────────────────────────────────────────

  @default_rules [
    %{
      id: "critical_bypass",
      type: :access,
      condition: %{priority: "critical"},
      action: :allow,
      note: "Critical priority bypasses hierarchy"
    },
    %{
      id: "hierarchy_enforce",
      type: :access,
      condition: %{cross_squad: true, sender_tier: [3, 4]},
      action: :deny,
      message: "Cross-squad messaging requires escalation"
    },
    %{
      id: "restricted_to_leader",
      type: :access,
      condition: %{sender_tier: [4], target_tier: [0, 1]},
      action: :deny,
      message: "Restricted agents cannot message leadership directly"
    },
    %{
      id: "rate_tier4",
      type: :rate_limit,
      condition: %{sender_tier: [4], action: :dm},
      limit: 5,
      per: :minute
    },
    %{
      id: "rate_tier3",
      type: :rate_limit,
      condition: %{sender_tier: [3], action: :dm},
      limit: 20,
      per: :minute
    },
    %{
      id: "auto_task_context",
      type: :transform,
      condition: %{sender_has_active_task: true},
      action: :attach_task_context
    }
  ]

  # ── Public API ─────────────────────────────────────────────

  @doc "Returns the default rules list."
  @spec default_rules() :: [map()]
  def default_rules, do: @default_rules

  @doc """
  Loads rules for a fleet from StorePort. Falls back to defaults
  if no fleet-specific rules exist.
  """
  @spec load_rules(String.t()) :: [map()]
  def load_rules(fleet_id) do
    key = "#{@store_prefix}:#{fleet_id}"

    case StorePort.get_document(key) do
      {:ok, %{meta: meta}} when byte_size(meta) > 0 ->
        case Jason.decode(meta) do
          {:ok, rules} when is_list(rules) ->
            Enum.map(rules, &atomize_rule/1)

          _ ->
            @default_rules
        end

      _ ->
        @default_rules
    end
  end

  @doc """
  Saves rules for a fleet to StorePort.
  """
  @spec save_rules(String.t(), [map()]) :: :ok | {:error, term()}
  def save_rules(fleet_id, rules) do
    key = "#{@store_prefix}:#{fleet_id}"
    json = Jason.encode!(Enum.map(rules, &stringify_rule/1))

    case StorePort.put_document(key, json, <<>>) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Evaluates all rules against an action context.

  ## Context map

  Expected keys:
  - `:action` — `:dm`, `:broadcast`, `:escalation`
  - `:sender_tier` — integer 0-4
  - `:target_tier` — integer 0-4 (for DMs)
  - `:cross_squad` — boolean
  - `:priority` — "low", "normal", "high", "critical"
  - `:sender_has_active_task` — boolean

  ## Returns

  - `:allow` — message passes all rules
  - `{:deny, reason}` — blocked by a rule
  - `{:transform, transforms}` — list of transform actions to apply
  """
  @spec evaluate([map()], atom(), map()) :: :allow | {:deny, String.t()} | {:transform, [atom()]}
  def evaluate(rules, action, context) do
    context = Map.put(context, :action, action)

    # Separate rule types
    access_rules = Enum.filter(rules, &(rule_type(&1) == :access))
    transform_rules = Enum.filter(rules, &(rule_type(&1) == :transform))

    # Evaluate access rules (first match wins)
    access_result = evaluate_access_rules(access_rules, context)

    case access_result do
      {:deny, reason} ->
        {:deny, reason}

      :allow ->
        # Collect transforms
        transforms =
          transform_rules
          |> Enum.filter(&condition_matches?(&1, context))
          |> Enum.map(&rule_action/1)
          |> Enum.reject(&is_nil/1)

        if transforms == [] do
          :allow
        else
          {:transform, transforms}
        end
    end
  end

  @doc """
  Adds a rule to a fleet's rule set (appended at the end).
  """
  @spec add_rule(String.t(), map()) :: :ok | {:error, term()}
  def add_rule(fleet_id, rule) do
    rules = load_rules(fleet_id)

    # Replace if same ID exists, otherwise append
    existing_index = Enum.find_index(rules, &(rule_id(&1) == rule_id(rule)))

    updated =
      if existing_index do
        List.replace_at(rules, existing_index, rule)
      else
        rules ++ [rule]
      end

    save_rules(fleet_id, updated)
  end

  @doc """
  Removes a rule by ID from a fleet's rule set.
  """
  @spec remove_rule(String.t(), String.t()) :: :ok | {:error, term()}
  def remove_rule(fleet_id, rule_id_str) do
    rules = load_rules(fleet_id)
    updated = Enum.reject(rules, &(rule_id(&1) == rule_id_str))
    save_rules(fleet_id, updated)
  end

  # ── Private ────────────────────────────────────────────────

  defp evaluate_access_rules([], _context), do: :allow

  defp evaluate_access_rules([rule | rest], context) do
    if condition_matches?(rule, context) do
      case rule_action(rule) do
        :allow -> :allow
        :deny -> {:deny, rule_message(rule)}
        _ -> evaluate_access_rules(rest, context)
      end
    else
      evaluate_access_rules(rest, context)
    end
  end

  defp condition_matches?(rule, context) do
    condition = rule_condition(rule)

    Enum.all?(condition, fn {key, expected} ->
      actual = Map.get(context, key)
      value_matches?(actual, expected)
    end)
  end

  defp value_matches?(actual, expected) when is_list(expected) do
    actual in expected
  end

  defp value_matches?(actual, expected) do
    actual == expected
  end

  # ── Rule field accessors (handle both atom and string keys) ─

  defp rule_type(rule), do: get_field(rule, :type, :access)
  defp rule_id(rule), do: get_field(rule, :id)
  defp rule_action(rule), do: get_field(rule, :action)
  defp rule_message(rule), do: get_field(rule, :message, "Denied by business rule")
  defp rule_condition(rule), do: get_field(rule, :condition, %{}) |> normalize_condition()

  defp get_field(map, key, default \\ nil) do
    val = Map.get(map, key) || Map.get(map, to_string(key))
    if is_nil(val), do: default, else: val
  end

  defp normalize_condition(condition) when is_map(condition) do
    Enum.map(condition, fn {k, v} ->
      key =
        cond do
          is_atom(k) -> k
          is_binary(k) -> String.to_existing_atom(k)
          true -> k
        end

      {key, v}
    end)
    |> Map.new()
  rescue
    ArgumentError -> condition
  end

  defp normalize_condition(other), do: other

  # ── Serialization helpers ──────────────────────────────────

  defp stringify_rule(rule) do
    rule
    |> Enum.map(fn {k, v} ->
      key = if is_atom(k), do: Atom.to_string(k), else: k

      value =
        cond do
          is_atom(v) -> Atom.to_string(v)
          is_map(v) -> stringify_rule(v)
          true -> v
        end

      {key, value}
    end)
    |> Map.new()
  end

  defp atomize_rule(rule) when is_map(rule) do
    rule
    |> Enum.map(fn {k, v} ->
      key =
        if is_binary(k) do
          try do
            String.to_existing_atom(k)
          rescue
            ArgumentError -> k
          end
        else
          k
        end

      value =
        cond do
          is_map(v) -> atomize_rule(v)
          is_binary(v) and v in ~w(access rate_limit transform allow deny attach_task_context minute hour) ->
            String.to_existing_atom(v)
          true -> v
        end

      {key, value}
    end)
    |> Map.new()
  end

  defp atomize_rule(other), do: other
end
