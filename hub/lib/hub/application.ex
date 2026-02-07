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

      # Challenge store for Ed25519 auth (ETS-backed, must start before Endpoint)
      {Hub.ChallengeStore, []},

      # TwMerge cache for SaladUI
      TwMerge.Cache,

      # Task orchestration (ETS-backed ephemeral task store + supervisor)
      {Hub.TaskInit, []},
      Hub.TaskSupervisor,
      {Hub.Workers.OllamaBridge, []},

      # Agent provisioning worker (async cloud provisioning)
      {Hub.ProvisioningWorker, []},

      # Prometheus-style metrics (ETS-backed, attaches telemetry handlers)
      {Hub.Metrics, []},

      # Alert checker (periodic alert rule evaluation)
      {Hub.Alerts, []},

      # Webhook dispatcher (outbound webhook delivery)
      {Hub.WebhookDispatcher, []},

      # Webhook event subscriber (bridges PubSub → WebhookDispatcher)
      {Hub.WebhookSubscriber, []},

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
