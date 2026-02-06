defmodule Hub.Memory do
  @moduledoc """
  Fleet-scoped shared memory backed by the Rust store.

  Provides CRUD + query operations on key-value memory entries that are
  shared across all agents in a fleet.  Each entry is persisted as a
  JSON-encoded document in `Hub.StorePort` with key format
  `mem:{fleet_id}:{user_key}`.

  Changes are broadcast via Phoenix PubSub so that subscribed
  FleetChannel processes can push real-time `memory:changed` events
  to connected agents.

  TTL values are stored but **not** enforced in the current MVP
  (no background sweeper).
  """

  require Logger

  alias Hub.StorePort

  @pubsub Hub.PubSub

  # ── Public API ─────────────────────────────────────────────

  @doc """
  Create or update a memory entry.

  ## Params (map with string keys)
    - `"value"` (required) — the content
    - `"tags"` — list of string tags (default `[]`)
    - `"type"` — content type (default `"text"`)
    - `"ttl"` — seconds until expiry, stored as ISO 8601 timestamp (default `nil`)
    - `"metadata"` — arbitrary map (default `%{}`)
    - `"author"` — agent id of the writer
  """
  @spec set(String.t(), String.t(), map()) :: {:ok, map()}
  def set(fleet_id, key, params) when is_binary(fleet_id) and is_binary(key) do
    store_key = store_key(fleet_id, key)
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    # Try to fetch existing entry for update semantics
    existing = fetch_raw(store_key)

    entry =
      case existing do
        {:ok, prev} ->
          prev
          |> Map.merge(%{
            "value" => Map.get(params, "value", prev["value"]),
            "tags" => Map.get(params, "tags", prev["tags"]),
            "type" => Map.get(params, "type", prev["type"]),
            "metadata" => Map.get(params, "metadata", prev["metadata"]),
            "author" => Map.get(params, "author", prev["author"]),
            "updated_at" => now,
            "ttl" => compute_ttl(Map.get(params, "ttl"))
          })

        :not_found ->
          %{
            "id" => "mem_" <> gen_uuid(),
            "key" => key,
            "fleet_id" => fleet_id,
            "value" => Map.get(params, "value", ""),
            "type" => Map.get(params, "type", "text"),
            "tags" => Map.get(params, "tags", []),
            "author" => Map.get(params, "author"),
            "created_at" => now,
            "updated_at" => now,
            "ttl" => compute_ttl(Map.get(params, "ttl")),
            "access_count" => 0,
            "metadata" => Map.get(params, "metadata", %{})
          }
      end

    meta_json = Jason.encode!(entry)
    :ok = StorePort.put_document(store_key, meta_json, <<>>)

    broadcast_change(fleet_id, key, "set", entry["author"])
    publish_to_event_bus(fleet_id, key, "set", entry)

    {:ok, entry}
  end

  @doc "Retrieve a memory entry by key, incrementing its access count."
  @spec get(String.t(), String.t()) :: {:ok, map()} | :not_found
  def get(fleet_id, key) when is_binary(fleet_id) and is_binary(key) do
    store_key = store_key(fleet_id, key)

    case fetch_raw(store_key) do
      {:ok, entry} ->
        # Bump access_count
        updated = Map.update(entry, "access_count", 1, &((&1 || 0) + 1))
        meta_json = Jason.encode!(updated)
        StorePort.put_document(store_key, meta_json, <<>>)
        {:ok, updated}

      :not_found ->
        :not_found
    end
  end

  @doc "Delete a memory entry. Returns `:ok` or `:not_found`."
  @spec delete(String.t(), String.t()) :: :ok | :not_found
  def delete(fleet_id, key) when is_binary(fleet_id) and is_binary(key) do
    store_key = store_key(fleet_id, key)

    case StorePort.get_document(store_key) do
      {:ok, _doc} ->
        StorePort.delete_document(store_key)
        broadcast_change(fleet_id, key, "delete", nil)
        publish_to_event_bus(fleet_id, key, "delete", %{})
        :ok

      :not_found ->
        :not_found

      {:error, _} ->
        :not_found
    end
  end

  @doc """
  List memory entries for a fleet.

  ## Options
    - `:limit` — max entries (default 50)
    - `:offset` — skip N entries (default 0)
    - `:tags` — filter by tags (entries must have ALL listed tags)
    - `:author` — filter by author agent_id
  """
  @spec list(String.t(), keyword()) :: {:ok, [map()]}
  def list(fleet_id, opts \\ []) do
    prefix = "mem:#{fleet_id}:"
    entries = load_fleet_entries(prefix)

    filtered =
      entries
      |> maybe_filter_tags(Keyword.get(opts, :tags))
      |> maybe_filter_author(Keyword.get(opts, :author))
      |> Enum.sort_by(& &1["updated_at"], :desc)
      |> maybe_offset(Keyword.get(opts, :offset, 0))
      |> maybe_limit(Keyword.get(opts, :limit, 50))

    {:ok, filtered}
  end

  @doc """
  Query/search memory entries.

  ## Options
    - `:tags` — filter by tags (all must match)
    - `:text_search` — substring match on key + value
    - `:author` — filter by author
    - `:since` — ISO 8601 datetime string, entries updated after this
    - `:limit` — max results (default 20)
    - `:sort` — `:relevance` | `:created_at` | `:updated_at` | `:access_count`
  """
  @spec query(String.t(), keyword()) :: {:ok, [map()]}
  def query(fleet_id, opts \\ []) do
    prefix = "mem:#{fleet_id}:"
    text_search = Keyword.get(opts, :text_search)

    entries =
      load_fleet_entries(prefix)
      |> maybe_filter_tags(Keyword.get(opts, :tags))
      |> maybe_filter_author(Keyword.get(opts, :author))
      |> maybe_filter_since(Keyword.get(opts, :since))
      |> maybe_filter_text(text_search)

    sorted =
      case Keyword.get(opts, :sort) do
        :access_count ->
          Enum.sort_by(entries, & &1["access_count"], :desc)

        :created_at ->
          Enum.sort_by(entries, & &1["created_at"], :desc)

        :relevance when is_binary(text_search) ->
          # Score by number of substring occurrences in key + value
          Enum.sort_by(entries, &(-relevance_score(&1, text_search)))

        _ ->
          Enum.sort_by(entries, & &1["updated_at"], :desc)
      end

    {:ok, maybe_limit(sorted, Keyword.get(opts, :limit, 20))}
  end

  @doc """
  Return the PubSub topic string for a memory subscription pattern.

  For exact key subscriptions: `"memory:{fleet_id}:{key}"`
  For wildcard (all changes):  `"memory:{fleet_id}:_all"`
  """
  @spec subscribe_pattern(String.t(), String.t()) :: String.t()
  def subscribe_pattern(fleet_id, pattern) do
    if String.contains?(pattern, "*") do
      "memory:#{fleet_id}:_all"
    else
      "memory:#{fleet_id}:#{pattern}"
    end
  end

  # ── Internal Helpers ───────────────────────────────────────

  defp store_key(fleet_id, key), do: "mem:#{fleet_id}:#{key}"

  defp fetch_raw(store_key) do
    case StorePort.get_document(store_key) do
      {:ok, %{meta: meta}} when byte_size(meta) > 0 ->
        {:ok, Jason.decode!(meta)}

      :not_found ->
        :not_found

      {:error, _} ->
        :not_found
    end
  end

  defp load_fleet_entries(prefix) do
    case StorePort.list_documents() do
      {:ok, ids} ->
        ids
        |> Enum.filter(&String.starts_with?(&1, prefix))
        |> Enum.reduce([], fn id, acc ->
          case fetch_raw(id) do
            {:ok, entry} -> [entry | acc]
            :not_found -> acc
          end
        end)

      {:error, reason} ->
        Logger.warning("[Hub.Memory] list_documents failed: #{inspect(reason)}")
        []
    end
  end

  defp maybe_filter_tags(entries, nil), do: entries
  defp maybe_filter_tags(entries, []), do: entries

  defp maybe_filter_tags(entries, tags) when is_list(tags) do
    tag_set = MapSet.new(tags)

    Enum.filter(entries, fn entry ->
      entry_tags = MapSet.new(entry["tags"] || [])
      MapSet.subset?(tag_set, entry_tags)
    end)
  end

  defp maybe_filter_author(entries, nil), do: entries

  defp maybe_filter_author(entries, author) do
    Enum.filter(entries, &(&1["author"] == author))
  end

  defp maybe_filter_since(entries, nil), do: entries

  defp maybe_filter_since(entries, since) when is_binary(since) do
    Enum.filter(entries, fn entry ->
      (entry["updated_at"] || "") >= since
    end)
  end

  defp maybe_filter_text(entries, nil), do: entries
  defp maybe_filter_text(entries, ""), do: entries

  defp maybe_filter_text(entries, text) do
    needle = String.downcase(text)

    Enum.filter(entries, fn entry ->
      haystack =
        String.downcase(entry["key"] || "") <>
          " " <> String.downcase(entry["value"] || "")

      String.contains?(haystack, needle)
    end)
  end

  defp maybe_offset(entries, 0), do: entries
  defp maybe_offset(entries, n), do: Enum.drop(entries, n)

  defp maybe_limit(entries, n), do: Enum.take(entries, n)

  defp relevance_score(entry, text) do
    needle = String.downcase(text)
    haystack = String.downcase((entry["key"] || "") <> " " <> (entry["value"] || ""))

    # Count occurrences
    parts = String.split(haystack, needle)
    length(parts) - 1
  end

  defp compute_ttl(nil), do: nil
  defp compute_ttl(seconds) when is_integer(seconds) and seconds > 0 do
    DateTime.utc_now()
    |> DateTime.add(seconds, :second)
    |> DateTime.to_iso8601()
  end
  defp compute_ttl(_), do: nil

  defp broadcast_change(fleet_id, key, action, author) do
    event = %{
      key: key,
      action: action,
      author: author,
      fleet_id: fleet_id,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    # Exact key topic
    Phoenix.PubSub.broadcast(@pubsub, "memory:#{fleet_id}:#{key}", {:memory_changed, event})
    # Wildcard / all-changes topic
    Phoenix.PubSub.broadcast(@pubsub, "memory:#{fleet_id}:_all", {:memory_changed, event})
  end

  defp publish_to_event_bus(fleet_id, key, action, entry) do
    bus_topic = "ringforge.#{fleet_id}.memory"

    bus_event = %{
      "key" => key,
      "action" => action,
      "entry" => entry,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    Task.start(fn ->
      case Hub.EventBus.publish(bus_topic, bus_event) do
        :ok -> :ok
        {:error, reason} ->
          Logger.warning("[Hub.Memory] EventBus publish failed: #{inspect(reason)}")
      end
    end)
  end

  defp gen_uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    [
      Base.encode16(<<a::32>>, case: :lower),
      Base.encode16(<<b::16>>, case: :lower),
      Base.encode16(<<c::16>>, case: :lower),
      Base.encode16(<<d::16>>, case: :lower),
      Base.encode16(<<e::48>>, case: :lower)
    ]
    |> Enum.join("-")
  end
end
