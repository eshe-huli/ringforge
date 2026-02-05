defmodule Hub.StorePort do
  @moduledoc """
  GenServer that manages the Rust storage engine as an Elixir Port.

  The Rust binary communicates via stdin/stdout using 4-byte big-endian
  length-prefixed bincode frames. Each frame carries a ref_id (u64) to
  match requests with responses.
  """
  use GenServer
  require Logger

  alias Hub.StoreProtocol

  # ── Public API ───────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Store a blob, returns {:ok, hash} or {:error, reason}."
  def put_blob(data) when is_binary(data) do
    GenServer.call(__MODULE__, {:put_blob, data}, 30_000)
  end

  @doc "Retrieve a blob by its hash. Returns {:ok, data} | :not_found | {:error, reason}."
  def get_blob(hash) when is_binary(hash) do
    GenServer.call(__MODULE__, {:get_blob, hash}, 30_000)
  end

  @doc "Check if a blob exists. Returns {:ok, boolean} | {:error, reason}."
  def has_blob(hash) when is_binary(hash) do
    GenServer.call(__MODULE__, {:has_blob, hash}, 30_000)
  end

  @doc "Store/update a document. meta and crdt_state are raw binaries."
  def put_document(id, meta \\ <<>>, crdt_state \\ <<>>)
      when is_binary(id) and is_binary(meta) and is_binary(crdt_state) do
    GenServer.call(__MODULE__, {:put_document, id, meta, crdt_state}, 30_000)
  end

  @doc "Retrieve a document by id."
  def get_document(id) when is_binary(id) do
    GenServer.call(__MODULE__, {:get_document, id}, 30_000)
  end

  @doc "Delete a document by id."
  def delete_document(id) when is_binary(id) do
    GenServer.call(__MODULE__, {:delete_document, id}, 30_000)
  end

  @doc "List all document ids."
  def list_documents do
    GenServer.call(__MODULE__, :list_documents, 30_000)
  end

  # ── GenServer callbacks ──────────────────────────────────────────────

  @impl true
  def init(opts) do
    binary = opts[:binary] || Application.get_env(:hub, :store_binary, "ringforge-store")
    data_dir = opts[:data_dir] || Application.get_env(:hub, :store_data_dir, "./data/store")

    # Ensure data directory exists
    File.mkdir_p!(data_dir)

    port =
      Port.open(
        {:spawn_executable, to_charlist(binary)},
        [
          :binary,
          :exit_status,
          {:args, ["--data-dir", data_dir]},
          {:packet, 4}
        ]
      )

    Logger.info("StorePort started: #{binary} --data-dir #{data_dir}")

    {:ok,
     %{
       port: port,
       ref_counter: 0,
       pending: %{},
       buffer: <<>>
     }}
  end

  @impl true
  def handle_call(request, from, state) do
    ref_id = state.ref_counter + 1

    # {:packet, 4} means the Port driver adds a 4-byte BE length prefix
    # on send and strips it on receive — matching the Rust wire format.
    # We send only the bincode payload (no length prefix from our side).
    payload = encode_payload_only(ref_id, request)
    Port.command(state.port, payload)

    pending = Map.put(state.pending, ref_id, from)
    {:noreply, %{state | ref_counter: ref_id, pending: pending}}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {ref_id, response} = StoreProtocol.decode_response(data)

    case Map.pop(state.pending, ref_id) do
      {nil, _pending} ->
        Logger.warning("StorePort received response for unknown ref_id=#{ref_id}")
        {:noreply, state}

      {from, pending} ->
        reply = translate_response(response)
        GenServer.reply(from, reply)
        {:noreply, %{state | pending: pending}}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.error("StorePort exited with status #{status}")
    # Reply to all pending callers with an error
    for {_ref_id, from} <- state.pending do
      GenServer.reply(from, {:error, {:port_exit, status}})
    end

    {:stop, {:port_exit, status}, %{state | pending: %{}}}
  end

  def handle_info(msg, state) do
    Logger.warning("StorePort unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{port: port}) do
    Port.close(port)
    :ok
  rescue
    _ -> :ok
  end

  # ── Internal helpers ─────────────────────────────────────────────────

  # Encode payload without the 4-byte length prefix (Port {:packet, 4} adds it).
  defp encode_payload_only(ref_id, request) do
    req_body =
      case request do
        {:put_blob, data} -> {:put_blob, data}
        {:get_blob, hash} -> {:get_blob, hash}
        {:has_blob, hash} -> {:has_blob, hash}
        {:put_document, id, meta, crdt_state} -> {:put_document, id, meta, crdt_state}
        {:get_document, id} -> {:get_document, id}
        {:delete_document, id} -> {:delete_document, id}
        :list_documents -> :list_documents
      end

    frame = StoreProtocol.encode_request(ref_id, req_body)
    # Strip the 4-byte length prefix since {:packet, 4} adds its own
    <<_len::32, payload::binary>> = frame
    payload
  end

  defp translate_response(:ok), do: :ok
  defp translate_response(:not_found), do: :not_found
  defp translate_response({:blob, data}), do: {:ok, data}
  defp translate_response({:blob_stored, hash}), do: {:ok, hash}
  defp translate_response({:blob_exists, exists}), do: {:ok, exists}

  defp translate_response({:document, id, meta, crdt_state}),
    do: {:ok, %{id: id, meta: meta, crdt_state: crdt_state}}

  defp translate_response({:document_list, ids}), do: {:ok, ids}
  defp translate_response({:error, message}), do: {:error, message}
end
