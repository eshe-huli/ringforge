defmodule Hub.EventReplay do
  @moduledoc """
  Event replay system for Ringforge fleets.

  Provides filtered replay of activity events from the EventBus,
  supporting time-range, kind, tag, and agent filters.

  Events are returned in a single batch for the MVP — streaming
  delivery is a v2 optimization.
  """

  require Logger

  @doc """
  Replay activity events for a fleet with optional filters.

  ## Options (from payload map with string keys)
    - `"from"` — ISO 8601 datetime, start of range (inclusive)
    - `"to"` — ISO 8601 datetime, end of range (inclusive)
    - `"kinds"` — list of event kind strings to include
    - `"tags"` — list of tags (event must have at least one matching tag)
    - `"agents"` — list of agent_ids (event must be from one of these agents)
    - `"limit"` — max events to return (default 100)

  Returns `{:ok, %{events: [...], total: N, from: "...", to: "..."}}`.
  """
  @spec replay(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def replay(fleet_id, filters \\ %{}) do
    bus_topic = "ringforge.#{fleet_id}.activity"
    limit = Map.get(filters, "limit", 100)

    # Fetch a generous number of events to filter down from
    fetch_limit = limit * 10

    case Hub.EventBus.replay(bus_topic, limit: fetch_limit) do
      {:ok, events} ->
        filtered =
          events
          |> maybe_filter_time_range(Map.get(filters, "from"), Map.get(filters, "to"))
          |> maybe_filter_kinds(Map.get(filters, "kinds"))
          |> maybe_filter_tags(Map.get(filters, "tags"))
          |> maybe_filter_agents(Map.get(filters, "agents"))
          |> Enum.take(limit)

        result = %{
          "events" => filtered,
          "total" => length(filtered),
          "from" => Map.get(filters, "from"),
          "to" => Map.get(filters, "to")
        }

        {:ok, result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Private Filters ────────────────────────────────────────

  defp maybe_filter_time_range(events, nil, nil), do: events

  defp maybe_filter_time_range(events, from, to) do
    Enum.filter(events, fn event ->
      ts = event["timestamp"]

      cond do
        is_nil(ts) -> false
        not is_nil(from) and ts < from -> false
        not is_nil(to) and ts > to -> false
        true -> true
      end
    end)
  end

  defp maybe_filter_kinds(events, nil), do: events
  defp maybe_filter_kinds(events, []), do: events

  defp maybe_filter_kinds(events, kinds) when is_list(kinds) do
    Enum.filter(events, fn event ->
      Map.get(event, "kind") in kinds
    end)
  end

  defp maybe_filter_tags(events, nil), do: events
  defp maybe_filter_tags(events, []), do: events

  defp maybe_filter_tags(events, tags) when is_list(tags) do
    tag_set = MapSet.new(tags)

    Enum.filter(events, fn event ->
      event_tags = MapSet.new(Map.get(event, "tags", []))
      # Event must have at least one matching tag
      not MapSet.disjoint?(tag_set, event_tags)
    end)
  end

  defp maybe_filter_agents(events, nil), do: events
  defp maybe_filter_agents(events, []), do: events

  defp maybe_filter_agents(events, agents) when is_list(agents) do
    agent_set = MapSet.new(agents)

    Enum.filter(events, fn event ->
      from_id = get_in(event, ["from", "agent_id"])
      MapSet.member?(agent_set, from_id)
    end)
  end
end
