defmodule Hub.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # Build cluster topology from Hub.Cluster config (env-driven)
    topology = Hub.Cluster.topologies()

    children =
      [
        # Telemetry (must start before other children that emit events)
        Hub.Telemetry,

        # Rust storage engine port
        {Hub.StorePort, []},

        # Cluster discovery (libcluster)
        {Cluster.Supervisor, [topology, [name: Hub.ClusterSupervisor]]},

        # Optional Redis connection (for distributed task store / cross-region PubSub)
        maybe_redis_child(),

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

        # Task orchestration (ephemeral task store + supervisor)
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

        # Message rate limiter (ETS-backed, per-agent rate tracking)
        {Hub.Messaging.RateLimiter, []},

        # MQTT bridge (IoT/domotic — disabled by default)
        mqtt_bridge_child(),

        # Graceful node drain handler (for clustered deployments)
        maybe_drainer_child(),

        # Phoenix endpoint (WebSocket transport)
        Hub.Endpoint,

        # Role seeder (seeds predefined roles after Repo is ready)
        {Hub.RoleSeeder, []}
      ]
      |> Enum.reject(&is_nil/1)

    opts = [strategy: :one_for_one, name: Hub.Supervisor]
    result = Supervisor.start_link(children, opts)

    result
  end

  @doc false
  def seed_roles do
    require Logger

    try do
      Hub.Roles.seed_predefined_roles()
      Logger.info("[Roles] Predefined role seeding completed")
    rescue
      e ->
        Logger.error("[Roles] Seeding failed: #{Exception.message(e)}")
    end
  end

  defp event_bus_child do
    case Application.get_env(:hub, :event_bus, Hub.EventBus.Local) do
      Hub.EventBus.Kafka -> Hub.EventBus.Kafka
      Hub.EventBus.Pulsar -> Hub.EventBus.Pulsar
      _ -> Hub.EventBus.Local
    end
  end

  defp mqtt_bridge_child do
    config = Application.get_env(:hub, Hub.MQTT.Bridge, [])

    if config[:enabled] do
      {Hub.MQTT.Bridge, []}
    else
      nil
    end
  end

  defp maybe_redis_child do
    redis_url = Application.get_env(:hub, :redis_url)

    if redis_url do
      {Redix, {redis_url, [name: Hub.Redis]}}
    else
      nil
    end
  end

  defp maybe_drainer_child do
    if Hub.Cluster.enabled?() do
      {Hub.Cluster.Drainer, []}
    else
      nil
    end
  end
end
