import Config

config :hub, Hub.Endpoint,
  url: [host: "localhost"],
  http: [port: 4000],
  server: true,
  adapter: Bandit.PhoenixAdapter,
  pubsub_server: Hub.PubSub,
  secret_key_base: "Rk9SZ0VfSFVCX1NFQ1JFVF9LRVlfQkFTRV82NF9CWVRFU19NSU5JTVVNXw==+ringforge_dev_only",
  live_view: [signing_salt: "ringforge_lv_salt"]

config :hub,
  cluster_topology: [
    hub: [
      strategy: Cluster.Strategy.Gossip,
      config: [
        port: 45892,
        if_addr: "0.0.0.0",
        multicast_addr: "230.1.1.251",
        multicast_ttl: 1
      ]
    ]
  ]

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

# Ecto / Postgres
config :hub, Hub.Repo,
  username: "sentinel",
  password: "sentinel_secret",
  hostname: "localhost",
  port: 5432,
  database: "ringforge_dev",
  pool_size: 10,
  migration_primary_key: [name: :id, type: :binary_id]

config :hub, ecto_repos: [Hub.Repo]

# Rust storage engine
config :hub,
  store_binary: System.get_env("RINGFORGE_STORE_BIN", Path.expand("../../store/target/release/ringforge-store", __DIR__)),
  store_data_dir: System.get_env("RINGFORGE_DATA_DIR", "./data/store")

# EventBus — Local (ETS) for dev, Kafka for production
config :hub, event_bus: Hub.EventBus.Local

config :hub, Hub.EventBus.Kafka,
  brokers: [{"localhost", 9094}],
  client_id: :ringforge_kafka
