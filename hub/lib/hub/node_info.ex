defmodule Hub.NodeInfo do
  @moduledoc """
  Provides metadata about the current Hub BEAM node.

  Used by presence tracking and the cluster health endpoint to
  identify which node an agent is connected to.
  """

  @started_at DateTime.utc_now()

  @doc "Returns the BEAM node name (e.g., :\"hub@10.0.0.1\")."
  def node_name, do: Node.self()

  @doc "Returns the node name as a string."
  def node_name_string, do: Atom.to_string(Node.self())

  @doc "Returns the configured region for this node."
  def region do
    Hub.Cluster.region()
  end

  @doc "Returns when this node was started (compile-time approximation)."
  def started_at, do: @started_at

  @doc "Returns a summary map suitable for inclusion in presence metadata."
  def to_map do
    %{
      node: node_name_string(),
      region: region(),
      started_at: DateTime.to_iso8601(started_at())
    }
  end

  @doc "Returns the number of connected BEAM nodes (excluding self)."
  def cluster_size do
    length(Node.list()) + 1
  end
end
