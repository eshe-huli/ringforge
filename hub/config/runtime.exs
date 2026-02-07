import Config

# ── Cluster Configuration ───────────────────────────────────
# All clustering is opt-in via environment variables.
# Default: standalone mode (no clustering).

cluster_strategy = System.get_env("CLUSTER_STRATEGY", "none")
hub_region = System.get_env("HUB_REGION", "local")

config :hub, Hub.Cluster,
  strategy: cluster_strategy,
  region: hub_region,
  # DNS strategy options (Kubernetes / Fly.io)
  dns_query: System.get_env("CLUSTER_DNS_QUERY", "ringforge-hub.internal"),
  dns_poll_interval: String.to_integer(System.get_env("CLUSTER_DNS_POLL_INTERVAL", "5000")),
  node_basename: System.get_env("CLUSTER_NODE_BASENAME", "hub"),
  # Gossip strategy options (VPS / dev)
  gossip_port: String.to_integer(System.get_env("CLUSTER_GOSSIP_PORT", "45892")),
  gossip_if_addr: System.get_env("CLUSTER_GOSSIP_IF_ADDR", "0.0.0.0"),
  gossip_multicast_addr: System.get_env("CLUSTER_GOSSIP_MULTICAST_ADDR", "230.1.1.251"),
  gossip_multicast_ttl: String.to_integer(System.get_env("CLUSTER_GOSSIP_MULTICAST_TTL", "1")),
  # Epmd strategy options (local multi-node dev)
  epmd_hosts: System.get_env("CLUSTER_EPMD_HOSTS", "hub1@127.0.0.1,hub2@127.0.0.1")

# ── Task Store ──────────────────────────────────────────────
# Default: ETS (single-node). Set TASK_STORE=redis for distributed.

task_store_adapter =
  case System.get_env("TASK_STORE", "ets") do
    "redis" -> Hub.TaskStore.Redis
    _ -> Hub.TaskStore.ETS
  end

config :hub, Hub.TaskStore,
  adapter: task_store_adapter

# ── Redis (optional) ────────────────────────────────────────
# Required when TASK_STORE=redis. Also used for cross-region PubSub.

redis_url = System.get_env("REDIS_URL")

if redis_url do
  config :hub, :redis_url, redis_url
end

# ── Database (production overrides) ─────────────────────────

if database_url = System.get_env("DATABASE_URL") do
  config :hub, Hub.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "10"))
end

# ── Endpoint (production overrides) ─────────────────────────

if secret_key_base = System.get_env("SECRET_KEY_BASE") do
  config :hub, Hub.Endpoint,
    secret_key_base: secret_key_base
end

if port = System.get_env("PORT") do
  config :hub, Hub.Endpoint,
    http: [ip: {0, 0, 0, 0}, port: String.to_integer(port)]
end

# ── Node Name (for clustering) ──────────────────────────────
# Set via --name flag or NODE_NAME env in release.
# Example: NODE_NAME=hub1@10.0.0.1 or NODE_NAME=hub@ringforge-hub-0.ringforge-hub.default.svc.cluster.local
