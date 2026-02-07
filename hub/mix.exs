defmodule Hub.MixProject do
  use Mix.Project

  def project do
    [
      app: :hub,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Hub.Application, []}
    ]
  end

  defp deps do
    [
      {:phoenix, "~> 1.7"},
      {:phoenix_pubsub, "~> 2.1"},
      {:phoenix_html, "~> 4.0"},
      {:phoenix_live_view, "~> 1.0"},
      {:salad_ui, "~> 0.14"},
      {:jason, "~> 1.4"},
      {:bandit, "~> 1.0"},
      {:libcluster, "~> 3.3"},
      {:horde, "~> 0.9"},
      {:delta_crdt, "~> 0.6"},
      {:telemetry, "~> 1.2"},
      {:telemetry_metrics, "~> 0.6"},
      {:telemetry_poller, "~> 1.0"},
      {:ecto_sql, "~> 3.11"},
      {:postgrex, "~> 0.19.0"},
      {:brod, "~> 3.16"},
      {:bcrypt_elixir, "~> 3.0"},
      {:stripity_stripe, "~> 3.2"},
      {:ex_aws, "~> 2.5"},
      {:ex_aws_s3, "~> 2.5"},
      {:sweet_xml, "~> 0.7"},
      {:hackney, "~> 1.20"},
      {:ueberauth, "~> 0.10"},
      {:ueberauth_github, "~> 0.8"},
      {:ueberauth_google, "~> 0.12"},
      {:redix, "~> 1.4"},
      {:tortoise311, "~> 0.12"},
      {:mix_audit, "~> 2.1", only: :dev, runtime: false}
    ]
  end
end
