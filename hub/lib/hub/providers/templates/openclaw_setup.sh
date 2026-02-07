#!/bin/bash
# RingForge Agent Cloud-Init Script
# Installs Docker, pulls the RingForge agent image, and connects to the fleet.
#
# Variables (replaced at provision time):
#   __HUB_URL__         - RingForge Hub WebSocket URL
#   __API_KEY__         - Auto-generated API key for this agent
#   __AGENT_NAME__      - Agent display name
#   __TEMPLATE__        - Template type (openclaw, bare, custom)

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "=== RingForge Agent Setup ==="
echo "Template: __TEMPLATE__"
echo "Agent: __AGENT_NAME__"

# --- System updates ---
apt-get update -qq
apt-get upgrade -y -qq

# --- Install Docker ---
apt-get install -y -qq \
  apt-transport-https \
  ca-certificates \
  curl \
  gnupg \
  lsb-release

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -qq
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin

systemctl enable docker
systemctl start docker

# --- Create agent config directory ---
mkdir -p /opt/ringforge
cat > /opt/ringforge/agent.env <<EOF
RINGFORGE_HUB_URL=__HUB_URL__
RINGFORGE_API_KEY=__API_KEY__
RINGFORGE_AGENT_NAME=__AGENT_NAME__
RINGFORGE_TEMPLATE=__TEMPLATE__
EOF

# --- Pull and run the RingForge agent ---
if [ "__TEMPLATE__" = "openclaw" ]; then
  # OpenClaw agent — full-featured with tool support
  docker pull ghcr.io/ringforge/agent:latest || echo "Image not yet available, will retry"
  docker run -d \
    --name ringforge-agent \
    --restart unless-stopped \
    --env-file /opt/ringforge/agent.env \
    -v /var/run/docker.sock:/var/run/docker.sock \
    ghcr.io/ringforge/agent:latest || echo "Container start deferred"
elif [ "__TEMPLATE__" = "bare" ]; then
  # Bare agent — minimal, just connects to the mesh
  docker pull ghcr.io/ringforge/agent-bare:latest || echo "Image not yet available, will retry"
  docker run -d \
    --name ringforge-agent \
    --restart unless-stopped \
    --env-file /opt/ringforge/agent.env \
    ghcr.io/ringforge/agent-bare:latest || echo "Container start deferred"
else
  echo "Custom template — manual setup required"
fi

# --- Setup auto-update cron ---
cat > /etc/cron.d/ringforge-update <<'CRON'
# Check for agent image updates every 6 hours
0 */6 * * * root docker pull ghcr.io/ringforge/agent:latest && docker restart ringforge-agent 2>/dev/null || true
CRON

echo "=== RingForge Agent Setup Complete ==="
