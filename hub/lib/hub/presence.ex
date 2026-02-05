defmodule Hub.Presence do
  @moduledoc """
  CRDT-backed presence tracker. Stores connected node/agent metadata
  in a DeltaCrdt that replicates automatically across the cluster.
  """
  use GenServer

  @crdt_name Hub.Presence.Crdt

  # ── Client API ──────────────────────────────────────────────

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc "Register a node with metadata."
  def register(node_id, meta \\ %{}) when is_binary(node_id) do
    GenServer.call(__MODULE__, {:register, node_id, meta})
  end

  @doc "Unregister a node."
  def unregister(node_id) when is_binary(node_id) do
    GenServer.call(__MODULE__, {:unregister, node_id})
  end

  @doc "List all present nodes."
  def list do
    GenServer.call(__MODULE__, :list)
  end

  # ── Server ──────────────────────────────────────────────────

  @impl true
  def init(:ok) do
    {:ok, crdt} =
      DeltaCrdt.start_link(DeltaCrdt.AWLWWMap,
        name: @crdt_name,
        sync_interval: 100
      )

    {:ok, %{crdt: crdt}}
  end

  @impl true
  def handle_call({:register, node_id, meta}, _from, state) do
    entry = Map.merge(meta, %{joined_at: System.system_time(:second)})
    DeltaCrdt.put(@crdt_name, node_id, entry)
    {:reply, :ok, state}
  end

  def handle_call({:unregister, node_id}, _from, state) do
    DeltaCrdt.delete(@crdt_name, node_id)
    {:reply, :ok, state}
  end

  def handle_call(:list, _from, state) do
    nodes = DeltaCrdt.to_map(@crdt_name)
    {:reply, nodes, state}
  end
end
