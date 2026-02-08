defmodule Hub.SquadMemory do
  @moduledoc """
  Squad-scoped shared memory backed by the Rust store.

  Mirrors `Hub.Memory` but keys are scoped to a squad rather than a fleet.
  Key format: `smem:{squad_id}:{user_key}`.

  Only agents belonging to the squad can read/write.
  Changes are broadcast on the squad PubSub topic so subscribed
  FleetChannel processes can push `squad:memory:changed` events.
  """

  require Logger

  alias Hub.StorePort

  @pubsub Hub.PubSub

  # ── Public API ─────────────────────────────────────────────

  @doc "Create or update a squad memory entry."
  @spec set(String.t(), String.t(), map()) :: {:ok, map()}
  def set(squad_id, key, params) when is_binary(squad_id) and is_binary(key) do
    store_key = store_key(squad_id, key)
    now = DateTime.utc_now() |> DateTime.to_iso8601()

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
            "id" => "smem_" <> gen_uuid(),
            "key" => key,
            "squad_id" => squad_id,
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

    broadcast_change(squad_id, key, "set", entry["author"])

    {:ok, entry}
  end

  @doc "Retrieve a squad memory entry by key."
  @spec get(String.t(), String.t()) :: {:ok, map()} | :not_found
  def get(squad_id, key) when is_binary(squad_id) and is_binary(key) do
    store_key = store_key(squad_id, key)

    case fetch_raw(store_key) do
      {:ok, entry} ->
        updated = Map.update(entry, "access_count", 1, &((&1 || 0) + 1))
        meta_json = Jason.encode!(updated)
        StorePort.put_document(store_key, meta_json, <<>>)
        {:ok, updated}

      :not_found ->
        :not_found
    end
  end

  @doc "Delete a squad memory entry."
  @spec delete(String.t(), String.t()) :: :ok | :not_found
  def delete(squad_id, key) when is_binary(squad_id) and is_binary(key) do
    store_key = store_key(squad_id, key)

    case StorePort.get_document(store_key) do
      {:ok, _doc} ->
        StorePort.delete_document(store_key)
        broadcast_change(squad_id, key, "delete", nil)
        :ok

      :not_found ->
        :not_found

      {:error, _} ->
        :not_found
    end
  end

  @doc "List squad memory entries."
  @spec list(String.t(), keyword()) :: {:ok, [map()]}
  def list(squad_id, opts \\ []) do
    prefix = "smem:#{squad_id}:"
    entries = load_entries(prefix)

    filtered =
      entries
      |> maybe_filter_tags(Keyword.get(opts, :tags))
      |> maybe_filter_author(Keyword.get(opts, :author))
      |> Enum.sort_by(& &1["updated_at"], :desc)
      |> maybe_offset(Keyword.get(opts, :offset, 0))
      |> maybe_limit(Keyword.get(opts, :limit, 50))

    {:ok, filtered}
  end

  # ── Internal Helpers ───────────────────────────────────────

  defp store_key(squad_id, key), do: "smem:#{squad_id}:#{key}"

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

  defp load_entries(prefix) do
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
        Logger.warning("[Hub.SquadMemory] list_documents failed: #{inspect(reason)}")
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

  defp maybe_offset(entries, 0), do: entries
  defp maybe_offset(entries, n), do: Enum.drop(entries, n)

  defp maybe_limit(entries, n), do: Enum.take(entries, n)

  defp compute_ttl(nil), do: nil
  defp compute_ttl(seconds) when is_integer(seconds) and seconds > 0 do
    DateTime.utc_now()
    |> DateTime.add(seconds, :second)
    |> DateTime.to_iso8601()
  end
  defp compute_ttl(_), do: nil

  defp broadcast_change(squad_id, key, action, author) do
    event = %{
      key: key,
      action: action,
      author: author,
      squad_id: squad_id,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    Phoenix.PubSub.broadcast(@pubsub, "squad:#{squad_id}", {:squad_memory_changed, event})
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
