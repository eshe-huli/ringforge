defmodule Hub.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    topology = Application.get_env(:hub, :cluster_topology, [])

    children = [
      # Telemetry (must start before other children that emit events)
      Hub.Telemetry,

      # Rust storage engine port
      {Hub.StorePort, []},

      # Cluster discovery
      {Cluster.Supervisor, [topology, [name: Hub.ClusterSupervisor]]},

      # PubSub
      {Phoenix.PubSub, name: Hub.PubSub},

      # Distributed registry (Horde)
      {Horde.Registry, [name: Hub.Registry, keys: :unique, members: :auto]},

      # Distributed dynamic supervisor (Horde)
      {Horde.DynamicSupervisor,
       [name: Hub.DynSupervisor, strategy: :one_for_one, members: :auto]},

      # Ecto Repo (Postgres)
      Hub.Repo,

      # CRDT-backed presence state (used by KeyringChannel)
      {Hub.Presence, []},

      # Phoenix.Presence for fleet channels
      Hub.FleetPresence,

      # EventBus backend (Local ETS or Kafka — selected by config)
      event_bus_child(),

      # Quota tracking (ETS-backed, must start before Endpoint)
      {Hub.Quota, []},

      # Phoenix endpoint (WebSocket transport)
      Hub.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Hub.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp event_bus_child do
    case Application.get_env(:hub, :event_bus, Hub.EventBus.Local) do
      Hub.EventBus.Kafka -> Hub.EventBus.Kafka
      _ -> Hub.EventBus.Local
    end
  end
end
