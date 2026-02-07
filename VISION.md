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

## The Future

### Phase 1: Foundation (Now)
- Hub running with Store backend
- Agent registration and presence
- Basic messaging (operator ↔ agent, agent ↔ agent)
- Health + metrics endpoints

### Phase 2: Dashboard + Messaging
- Web dashboard (React/Next.js or LiveView)
- Real-time agent status
- Direct messaging UI
- Message persistence in Store

### Phase 3: Pods & Task Coordination
- Pod CRUD (create, add/remove agents, delete)
- Pod channels (shared message streams)
- Task model (create, assign to pod, track progress)
- Agent task claiming and completion

### Phase 4: Intelligence Layer
- Smart routing (match tasks to best-capable agents)
- Auto-scaling (spin up agents when queue is deep)
- Cross-pod coordination (escalation, handoff)
- Audit trail for everything

### Phase 5: AI Departments
- Department templates (Engineering, Research, Ops, QA)
- Hierarchical pods (team leads, individual contributors)
- Budget/cost tracking per department
- SLA enforcement

## Design Principles

1. **Agents are first-class citizens** — not afterthoughts bolted onto a sync engine
2. **The human is the CEO** — full visibility, full control, minimal overhead
3. **Coordination > Communication** — messaging exists to enable coordination, not chat
4. **Offline-resilient** — agents that disconnect don't lose their place
5. **Observable by default** — every action emits events, everything is auditable

## Technical Foundation

| Layer | Tech | Purpose |
|-------|------|---------|
| Hub | Elixir/OTP | Agent connections, presence, routing, channels |
| Store | Rust (redb) | Persistent messages, documents, task state |
| Edge | Go | Agent-side client library |
| Dashboard | TBD (LiveView or React) | Operator UI |
| Relay | Redis Streams | Bridge to existing OpenClaw agents |

---

*"The goal is to allow multiple agents to communicate, me having a dashboard to see how many agents are inside, agents to connect easily, me having the ability to write to each, while also the ability to create groups/pods, and I can give tasks there and agents can coordinate there before each goes to do a task. This in a future can help me create whole departments of AI."*

— Ben Ouattara, 2026-02-06
