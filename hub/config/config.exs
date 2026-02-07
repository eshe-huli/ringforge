import Config

config :hub, Hub.Endpoint,
  url: [host: "localhost"],
  http: [ip: {0, 0, 0, 0}, port: 4000],
  server: true,
  adapter: Bandit.PhoenixAdapter,
  pubsub_server: Hub.PubSub,
  secret_key_base: System.get_env("SECRET_KEY_BASE", :crypto.strong_rand_bytes(64) |> Base.encode64()),
  live_view: [signing_salt: "ringforge_lv_salt"]

# Cluster — defaults to standalone (no clustering).
# Override via CLUSTER_STRATEGY env var: none, gossip, dns, epmd
config :hub, Hub.Cluster,
  strategy: "none",
  region: "local"

# Task store — defaults to ETS (single-node).
# Override via TASK_STORE env var: ets, redis
config :hub, Hub.TaskStore,
  adapter: Hub.TaskStore.ETS

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

# Ecto / Postgres
config :hub, Hub.Repo,
  username: "sentinel",
  password: System.get_env("DB_PASSWORD", "sentinel_secret"),
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
# Stripe billing
config :stripity_stripe,
  api_key: System.get_env("STRIPE_SECRET_KEY")

config :hub, :stripe,
  webhook_secret: System.get_env("STRIPE_WEBHOOK_SECRET"),
  price_ids: %{
    "pro" => System.get_env("STRIPE_PRICE_PRO", "price_pro_placeholder"),
    "scale" => System.get_env("STRIPE_PRICE_SCALE", "price_scale_placeholder"),
    "enterprise" => System.get_env("STRIPE_PRICE_ENTERPRISE", "price_enterprise_placeholder")
  },
  success_url: System.get_env("STRIPE_SUCCESS_URL", "http://localhost:4000/dashboard?billing=success"),
  cancel_url: System.get_env("STRIPE_CANCEL_URL", "http://localhost:4000/dashboard?billing=canceled")

# Billing plan limits — used by Hub.Quota to resolve limits dynamically
config :hub, Hub.Billing,
  plans: %{
    "free" => %{
      price_id: nil,
      agents: 10,
      messages_per_day: 50_000,
      memory_entries: 5_000,
      fleets: 1,
      storage_bytes: 1_073_741_824
    },
    "pro" => %{
      price_id: System.get_env("STRIPE_PRO_PRICE_ID"),
      agents: 100,
      messages_per_day: 500_000,
      memory_entries: 100_000,
      fleets: 5,
      storage_bytes: 26_843_545_600
    },
    "scale" => %{
      price_id: System.get_env("STRIPE_SCALE_PRICE_ID"),
      agents: 1_000,
      messages_per_day: 5_000_000,
      memory_entries: 1_000_000,
      fleets: 25,
      storage_bytes: 268_435_456_000
    },
    "enterprise" => %{
      price_id: nil,
      agents: :unlimited,
      messages_per_day: :unlimited,
      memory_entries: :unlimited,
      fleets: :unlimited,
      storage_bytes: :unlimited
    }
  }

# S3 (Garage) for file distribution
config :hub, Hub.S3,
  endpoint: System.get_env("S3_ENDPOINT", "http://localhost:3900"),
  access_key: System.get_env("S3_ACCESS_KEY", "GK6a9b5c80e50c581b2db950ea"),
  secret_key: System.get_env("S3_SECRET_KEY", "88abf9807e981e7407a048d95cbe61a911c83f92a02ed119b0f940544511d51c"),
  bucket: System.get_env("S3_BUCKET", "ringforge-files"),
  region: System.get_env("S3_REGION", "keyring")

# ExAws base config — Garage-compatible
config :ex_aws,
  json_codec: Jason,
  access_key_id: [{:system, "S3_ACCESS_KEY"}, "GK6a9b5c80e50c581b2db950ea"],
  secret_access_key: [{:system, "S3_SECRET_KEY"}, "88abf9807e981e7407a048d95cbe61a911c83f92a02ed119b0f940544511d51c"],
  region: "keyring"

config :ex_aws, :s3,
  scheme: "http://",
  host: "localhost",
  port: 3900,
  region: "keyring"

# Ueberauth — Social login (GitHub + Google)
config :ueberauth, Ueberauth,
  providers: [
    github: {Ueberauth.Strategy.Github, [default_scope: "user:email"]},
    google: {Ueberauth.Strategy.Google, [default_scope: "email profile"]}
  ]

config :ueberauth, Ueberauth.Strategy.Github.OAuth,
  client_id: System.get_env("GITHUB_CLIENT_ID"),
  client_secret: System.get_env("GITHUB_CLIENT_SECRET")

config :ueberauth, Ueberauth.Strategy.Google.OAuth,
  client_id: System.get_env("GOOGLE_CLIENT_ID"),
  client_secret: System.get_env("GOOGLE_CLIENT_SECRET")

# Registration mode — "open" or "invite_only"
config :hub, Hub.Auth,
  registration_mode: System.get_env("REGISTRATION_MODE", "invite_only")

# EventBus adapter — switch via EVENT_BUS_ADAPTER=kafka (default: local)
config :hub,
  event_bus:
    System.get_env("EVENT_BUS_ADAPTER", "local")
    |> then(fn
      "kafka" -> Hub.EventBus.Kafka
      "pulsar" -> Hub.EventBus.Pulsar
      _ -> Hub.EventBus.Local
    end)

# Webhook dispatcher configuration
config :hub, Hub.WebhookDispatcher,
  max_retries: 3,
  timeout_ms: 10_000,
  retry_delays: [30_000, 300_000]

config :hub, Hub.EventBus.Kafka,
  brokers: [{"localhost", String.to_integer(System.get_env("KAFKA_PORT", "9094"))}],
  client_id: :ringforge_kafka

# MQTT Bridge (IoT/Domotic — disabled by default)
config :hub, Hub.MQTT.Bridge,
  enabled: System.get_env("MQTT_ENABLED", "false") == "true",
  broker: System.get_env("MQTT_BROKER", "mqtt://localhost:1883"),
  client_id: System.get_env("MQTT_CLIENT_ID", "ringforge-hub"),
  topics: System.get_env("MQTT_TOPICS", "home/#,sensors/#") |> String.split(","),
  username: System.get_env("MQTT_USERNAME"),
  password: System.get_env("MQTT_PASSWORD")

# Pulsar EventBus
config :hub, Hub.EventBus.Pulsar,
  service_url: System.get_env("PULSAR_URL", "pulsar://localhost:6650"),
  web_service_url: System.get_env("PULSAR_WEB_URL", "http://localhost:8080"),
  tenant: "ringforge",
  namespace: "default"
