[![CI](https://github.com/eshe-huli/ringforge/actions/workflows/ci.yml/badge.svg)](https://github.com/eshe-huli/ringforge/actions/workflows/ci.yml)

# Ringforge

**A distributed agent mesh runtime** — real-time coordination and task orchestration infrastructure for AI agent fleets.

## Components

| Directory | Language | Role |
|-----------|----------|------|
| `hub/`    | Elixir/OTP | Coordination & orchestration — Phoenix Channels, presence, messaging, shared memory, task routing |
| `hub/lib/hub/workers/` | Elixir | Worker bridges — Ollama models and custom workers as fleet agents |
| `store/`  | Rust | Storage engine — redb, BLAKE3, stdin/stdout port |
| `proto/`  | Protobuf | Shared protocol definitions |
| `infra/`  | Docker/Helm | Deployment, CI/CD |

## Features

- **Agent presence** — real-time online/busy/away state tracking via Phoenix.Presence
- **Fleet channels** — agents join fleet topics, see each other, coordinate
- **Task orchestration** — submit tasks with capability requirements, auto-route to best available agent
- **Ollama bridge** — local LLM models (qwen2.5-coder, llama3.1, etc.) run as fleet peers
- **Direct messaging** — structured DMs with offline queue and auto-delivery
- **Shared memory** — key-value store backed by Rust, PubSub subscriptions
- **Activity broadcast** — task lifecycle events, tagged subscriptions
- **Event replay** — catch up on missed events by time/kind/tag/agent
- **Admin API** — tenant/fleet/agent/key CRUD with quota enforcement
- **LiveView dashboard** — real-time ops center with Add Agent wizard, zero JS build

## Quick Start

```bash
cd hub
mix setup        # deps + create DB + migrate + seed
mix phx.server   # start on port 4000
```

## Architecture

Agents connect via WebSocket (`/ws/websocket?vsn=2.0.0`), authenticate with API keys (Ed25519 challenge-response for reconnects), and join fleet channels. All coordination happens over Phoenix Channels with a custom JSON envelope protocol.

## Wire Protocol

```json
{"type": "<type>", "action": "<action>", "ref": "<correlation_id>", "payload": {}}
```

Types: `auth`, `presence`, `activity`, `memory`, `direct`, `replay`, `system`, `task`

### Task Submission (Quick Start)

```json
{
  "type": "task",
  "action": "submit",
  "ref": "t_001",
  "payload": {
    "description": "Review this pull request for security issues",
    "capabilities": ["code-review", "security"],
    "priority": "normal"
  }
}
```

The Hub matches the task to the best available agent by capabilities and load, then routes it automatically.

## License

Apache 2.0
