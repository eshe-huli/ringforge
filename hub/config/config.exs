import Config

config :hub, Hub.Endpoint,
  url: [host: "localhost"],
  http: [port: 4000],
  server: true,
  adapter: Bandit.PhoenixAdapter,
  pubsub_server: Hub.PubSub

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
