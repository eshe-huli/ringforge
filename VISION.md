# Ringforge Vision

## The Why

**One person. Entire AI departments.**

Ringforge is not a sync engine or a CRDT library. It's the **operating system for AI agent teams** — the infrastructure that lets one human command departments of AI agents the way a CEO commands divisions.

## The Problem

Today, AI agents are isolated. Each runs in its own session, can't see other agents, can't coordinate, can't share work. Managing a handful of agents already requires manual relay hacks. Managing 10, 50, 200 agents? Impossible without infrastructure.

## The Product

### Core Capabilities

1. **Agent Hub** — Agents connect to Ringforge via WebSocket. They register their identity, capabilities, and status. Always-on presence tracking shows who's online, what they can do, and what they're working on.

2. **Dashboard** — A web UI where the human operator can:
   - See all connected agents (online/offline/busy)
   - View agent capabilities, load, and current tasks
   - Send messages to individual agents
   - Create groups/pods of agents
   - Assign tasks to groups
   - Monitor task progress in real-time

3. **Direct Messaging** — The operator can write to any agent. Agents can write to each other. All messages are persistent and auditable.

4. **Pods (Agent Groups)** — Logical groupings of agents:
   - `backend-team`: 3 coding agents + 1 review agent
   - `research-pod`: 2 web researchers + 1 synthesizer
   - `ops-team`: infra agent + monitoring agent
   - Pods have shared context, shared task queues, and a coordination channel

5. **Task Assignment & Coordination** — Assign a task to a pod. Agents within the pod:
   - See the task in their shared queue
   - Coordinate in the pod channel (who does what)
   - Claim subtasks
   - Report progress
   - The pod completes when all subtasks are done

6. **Easy Onboarding** — Adding a new agent should be trivial:
   - Generate a token: `ringforge agent create --name "coder-3" --capabilities code,review`
   - Agent connects with the token
   - Appears in dashboard immediately
   - Can be added to pods

## The Evolution

RingForge started as a **coordination mesh** — agents share presence, memory, messages. The design principle was "coordination, not orchestration."

Phase 8 changed this. With task orchestration, capability routing, and the Ollama bridge, RingForge now provides **both patterns**:
- **Coordination:** Presence, shared memory, direct messaging, activity broadcast — agents are aware of each other and share context.
- **Orchestration:** Task submission, capability matching, work distribution — the Hub routes tasks to the best available agent automatically.

The mesh coordinates. The task system orchestrates. RingForge is infrastructure that enables both.

### Local Model Workers — A Paradigm Shift

The Ollama bridge introduced a new concept: **LLMs as fleet peers**. A local 7B model running via Ollama has the same status in the mesh as a cloud-hosted OpenClaw agent. They register capabilities, receive routed tasks, and return results through the same protocol.

This is the first multi-modal fleet:
- **Cloud LLMs** (via OpenClaw agents) — Claude, GPT, etc.
- **Local LLMs** (via Ollama bridge) — qwen2.5-coder, llama3.1, any Ollama model
- **Custom workers** — any process that speaks the wire protocol

The Hub doesn't care what's behind the agent. It routes based on capabilities and load.

## The Phases

### ✅ Phase 1-2: Foundation & Presence
- Hub running with Elixir/OTP
- Agent registration, Ed25519 auth, real-time presence
- Fleet channels, basic messaging

### ✅ Phase 3-5: Coordination Layer
- Activity broadcast, shared memory, direct messaging
- Event replay for catch-up
- Full coordination mesh operational

### ✅ Phase 6-7: Operations & Dashboard
- Admin REST API with quotas
- LiveView dashboard (6 pages, real-time ops center)
- Add Agent wizard for dead-simple onboarding

### ✅ Phase 8: Task Orchestration
- Task submission with capability requirements
- Capability-based routing (match task → best agent)
- Ollama bridge (local LLMs as fleet workers)
- Work distribution through the mesh

### Next: SDKs, OpenClaw Plugin, SaaS
- TypeScript/Python SDK publishing
- OpenClaw RingForge plugin (agents auto-connect to mesh)
- Stripe billing, social login, file distribution
- Domotic/IoT support (lightweight agents for embedded devices)

## The Future

### AI Departments
- Department templates (Engineering, Research, Ops, QA)
- Hierarchical pods (team leads, individual contributors)
- Budget/cost tracking per department
- SLA enforcement
- Mixed fleets: cloud LLMs, local LLMs, specialized workers

### Domotic & IoT
- Lightweight agents for home automation and IoT devices
- Sensor data as fleet memory
- Device health as presence
- MQTT bridge for existing ecosystems

## Design Principles

1. **Agents are first-class citizens** — not afterthoughts bolted onto a sync engine
2. **The human is the CEO** — full visibility, full control, minimal overhead
3. **Coordination + Orchestration** — the mesh coordinates (presence, memory); the task system orchestrates (routing, distribution)
4. **Offline-resilient** — agents that disconnect don't lose their place
5. **Observable by default** — every action emits events, everything is auditable

## Target Audience

1. **Vibecoders & non-technical builders** — people who use AI agents but aren't deep engineers. The Add Agent wizard, simple dashboard, and managed orchestration make fleet coordination accessible.
2. **Solo operators running AI teams** — one person commanding departments of AI agents. RingForge is the infrastructure that makes this possible.
3. **Framework authors** — LangChain, CrewAI, OpenClaw, custom agents. RingForge is framework-agnostic infrastructure.

## Technical Foundation

| Layer | Tech | Purpose |
|-------|------|---------|
| Hub | Elixir/OTP | Agent connections, presence, routing, task orchestration |
| Store | Rust (redb) | Persistent messages, documents |
| Workers | Ollama Bridge + custom | Local LLM models and specialized workers as fleet agents |
| Dashboard | Phoenix LiveView | Real-time ops center, agent management, task monitoring |
| SDKs | TypeScript, Python | Client libraries for agent integration |

---

*"The goal is to allow multiple agents to communicate, me having a dashboard to see how many agents are inside, agents to connect easily, me having the ability to write to each, while also the ability to create groups/pods, and I can give tasks there and agents can coordinate there before each goes to do a task. This in a future can help me create whole departments of AI."*

— Ben Ouattara, 2026-02-06
