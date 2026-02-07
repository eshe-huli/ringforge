defmodule Hub.Providers.CloudInit do
  @moduledoc """
  Generates cloud-init user-data scripts for provisioned agents.

  Reads the template from `templates/openclaw_setup.sh` and replaces
  placeholder variables with actual values.
  """

  @template_path Path.join(:code.priv_dir(:hub) |> to_string(), "../lib/hub/providers/templates/openclaw_setup.sh")

  @doc "Generate a cloud-init script with the given parameters."
  def generate(opts) do
    hub_url = opts[:hub_url] || System.get_env("RINGFORGE_HUB_URL", "wss://hub.ringforge.io/socket")
    api_key = opts[:api_key] || raise "api_key is required"
    agent_name = opts[:agent_name] || "rf-agent"
    template = opts[:template] || "openclaw"

    template_content()
    |> String.replace("__HUB_URL__", hub_url)
    |> String.replace("__API_KEY__", api_key)
    |> String.replace("__AGENT_NAME__", agent_name)
    |> String.replace("__TEMPLATE__", template)
  end

  defp template_content do
    case File.read(@template_path) do
      {:ok, content} -> content
      {:error, _} -> default_template()
    end
  end

  defp default_template do
    ~S"""
    #!/bin/bash
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq && apt-get install -y -qq docker.io
    systemctl enable docker && systemctl start docker
    mkdir -p /opt/ringforge
    cat > /opt/ringforge/agent.env <<EOF
    RINGFORGE_HUB_URL=__HUB_URL__
    RINGFORGE_API_KEY=__API_KEY__
    RINGFORGE_AGENT_NAME=__AGENT_NAME__
    EOF
    docker pull ghcr.io/ringforge/agent:latest || true
    docker run -d --name ringforge-agent --restart unless-stopped \
      --env-file /opt/ringforge/agent.env ghcr.io/ringforge/agent:latest || true
    """
  end
end
