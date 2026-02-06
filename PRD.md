# RingForge — Product Requirements Document

> **Version:** 1.0.0-draft
> **Author:** Argus (AI Assistant) — commissioned by Ben (CTO)
> **Date:** 2026-02-06
> **Status:** Draft — Awaiting Review
> **Repository:** https://github.com/eshe-huli/ringforge

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Problem Statement](#2-problem-statement)
3. [Target Users](#3-target-users)
4. [Product Vision](#4-product-vision)
5. [Core Features (MVP)](#5-core-features-mvp)
6. [System Architecture](#6-system-architecture)
7. [Protocol Specification](#7-protocol-specification)
8. [Multi-Tenancy Design](#8-multi-tenancy-design)
9. [Client SDKs](#9-client-sdks)
10. [Security](#10-security)
11. [Pricing Model](#11-pricing-model)
12. [Competitive Analysis](#12-competitive-analysis)
13. [Roadmap](#13-roadmap)
14. [Success Metrics](#14-success-metrics)
15. [Appendices](#15-appendices)

---

## 1. Executive Summary

### 1.1 What Is RingForge?

RingForge is a **multi-tenant agent mesh platform** that gives AI agent fleets a shared consciousness. It is the connective tissue between autonomous agents — regardless of their framework, language, or hosting environment.

Any AI agent — OpenClaw, LangChain, CrewAI, AutoGPT, a raw OpenAI API wrapper, or a hand-rolled Python script — can connect to RingForge via a WebSocket with an API key. Once connected, that agent gains:

- **Shared Awareness:** Real-time broadcast of what every agent in the fleet is doing.
- **Shared Memory:** A collective knowledge layer where insights, discoveries, and context are pooled.
- **Presence:** Immediate knowledge of who's online, their capabilities, and their current state.
- **Activity Feeds:** A durable, replayable log of everything the fleet has done — so new agents can "catch up" instantly.

RingForge does **not** orchestrate agents. It does not tell them what to do. It gives them the infrastructure to coordinate themselves — peer-to-peer, in real time, at scale.

### 1.2 Who Is It For?

- **Developers** building multi-agent systems who need agents to share context without building custom infrastructure.
- **Companies** deploying agent teams (customer support fleets, research teams, DevOps squads) that must coordinate without a human in the loop.
- **AI Platform Builders** who want to offer multi-agent capabilities to their users without reinventing the communication layer.
- **Indie Hackers / Power Users** running personal agent fleets (like the Warden Key prototype) who want their agents to be smarter together.

### 1.3 Why Now?

The agent ecosystem is at an inflection point:

- **2024:** Single agents became useful (ChatGPT, Claude, Copilot).
- **2025:** Multi-agent frameworks exploded (CrewAI, AutoGen, LangGraph, Swarm).
- **2026:** The bottleneck is no longer "can I build one agent?" — it's "how do I make many agents work together?"

Every existing solution treats this as an **orchestration** problem: one central brain assigns tasks to sub-agents. This is a dead end for real-world complexity. What's needed is **coordination** — agents that discover each other, share context, and self-organize.

RingForge is infrastructure, not an agent framework. It's the WebSocket mesh that makes any agent framework multi-agent-aware. It's HTTP for agent coordination.

### 1.4 One-Line Pitch

> **RingForge: Shared consciousness for AI agent fleets.**

---

## 2. Problem Statement

### 2.1 The Agent Island Problem

Today's AI agents are islands. Each agent:

- Starts with zero context about what other agents are doing.
- Has no way to discover peers without hardcoded integrations.
- Cannot share learned knowledge without custom database plumbing.
- Repeats work that other agents in the same organization have already done.
- Cannot coordinate in real-time without a human mediator or a rigid orchestration graph.

This is not a framework problem — it's an infrastructure problem. CrewAI can orchestrate a crew, but two different CrewAI crews can't talk to each other. A LangChain agent and a custom Python agent have no shared protocol at all.

### 2.2 The Orchestration Trap

The industry's answer to multi-agent coordination has been **orchestration**: a central controller that assigns tasks, routes messages, and manages state. This approach has fundamental limitations:

| Problem | Impact |
|---------|--------|
| **Single point of failure** | Orchestrator dies → entire fleet dies |
| **Scaling bottleneck** | All communication routes through one node |
| **Framework lock-in** | Orchestrator only works with its own agent type |
| **Rigid topology** | DAG/graph must be defined upfront; can't handle emergent coordination |
| **No shared memory** | Agents can't learn from each other's experiences |
| **No presence** | Agents don't know who else is online or what they're capable of |
| **No replay** | New agents start from scratch every time |

### 2.3 What's Actually Needed

The missing layer in the agent ecosystem is a **coordination mesh** — a shared bus where agents can:

1. **Announce** their presence and capabilities.
2. **Broadcast** their activities in real time.
3. **Store** and **retrieve** shared knowledge.
4. **Replay** historical events to build context.
5. **Reference** shared files and artifacts.
6. **Discover** peers without hardcoded addresses.

This is what RingForge provides. Not another framework. Not another orchestrator. A **mesh**.

### 2.4 The Analogy

Think of it this way:

- **Without RingForge:** Agents are like employees in separate rooms with no phones, no email, and no shared drive. Each one works alone. You (the human) run between rooms passing notes.
- **With RingForge:** Agents are in a shared office with whiteboards, a chat system, shared documents, and an activity feed. They self-organize. You set goals and check results.

---

## 3. Target Users

### 3.1 Primary Personas

#### Persona 1: The Agent Developer

> **"I'm building a multi-agent system and I don't want to build the communication layer from scratch."**

- **Who:** Individual developers or small teams building agent-powered products.
- **Pain:** Every multi-agent project requires custom WebSocket/pubsub/database plumbing. They rebuild the same infrastructure every time.
- **Need:** A drop-in SDK that gives their agents presence, messaging, and shared memory in under 10 lines of code.
- **Value:** Saves 2-4 weeks of infrastructure work per project.

#### Persona 2: The AI Team Lead

> **"I have 10 agents deployed across different services. I need them to coordinate without me babysitting."**

- **Who:** Technical leads at companies with production agent deployments.
- **Pain:** Agents duplicate work, miss context, and can't respond to changing conditions without human intervention.
- **Need:** A real-time coordination layer that lets agents share context and self-organize.
- **Value:** Reduces coordination overhead by 60-80%. Agents become a team, not a collection of individuals.

#### Persona 3: The Platform Builder

> **"My platform lets users create agents. I need to add multi-agent capabilities without building a mesh from scratch."**

- **Who:** Companies building agent platforms (similar to how Stripe builds on payment rails).
- **Pain:** Building a multi-tenant, scalable agent mesh is a 6-12 month engineering effort.
- **Need:** A white-label or API-based mesh they can embed in their platform.
- **Value:** Adds multi-agent capabilities to their product in days instead of months.

#### Persona 4: The Power User / Indie Hacker

> **"I run my own agents (OpenClaw, custom scripts) and I want them to share a brain."**

- **Who:** Technical users running personal agent fleets for productivity, research, or automation.
- **Pain:** Agents are disconnected. Personal assistant doesn't know what research agent found. Code agent doesn't know what deployment agent changed.
- **Need:** Simple, affordable mesh that connects their heterogeneous agent setup.
- **Value:** Personal agent fleet becomes a coherent team.

### 3.2 Anti-Personas (Not Target Users)

- **Non-technical users** who want a no-code agent builder. (RingForge is infrastructure, not a UI.)
- **Single-agent deployments** that don't need coordination. (Use RingForge when you have 2+ agents.)
- **Users who need a specific orchestration framework.** (RingForge complements frameworks; it doesn't replace them.)

---

## 4. Product Vision

### 4.1 The 3-Year Arc

#### Year 1 (2026): Foundation — "The Mesh Works"

- Ship MVP: WebSocket mesh with presence, activity broadcast, shared memory, event replay.
- Launch SDKs: TypeScript, Python, Go, OpenClaw plugin.
- Prove the model: 100+ active fleets, 1,000+ connected agents.
- Establish the protocol: RingForge Protocol v1.0 becomes a de-facto standard for agent coordination.
- Self-host option available from day one.

#### Year 2 (2027): Intelligence — "The Mesh Thinks"

- **Semantic memory layer:** Agents don't just store key-value pairs — the mesh understands relationships between memories across the fleet.
- **Agent capability discovery:** Agents register capabilities; the mesh can route requests to the most capable agent.
- **Cross-fleet coordination:** With permission, agents from different tenants can collaborate (marketplace model).
- **Analytics dashboard:** Fleet operators see coordination patterns, bottlenecks, and agent performance.
- **Managed deployment:** RingForge Cloud handles all infrastructure. Self-host remains an option.

#### Year 3 (2028): Ecosystem — "The Mesh Grows"

- **Agent marketplace:** Publish and subscribe to specialized agents that plug into any fleet.
- **Protocol adoption:** RingForge Protocol becomes an open standard. Other platforms implement it.
- **Enterprise features:** SSO, audit logs, compliance (SOC 2), on-prem deployment.
- **Federation:** Multiple RingForge instances can peer, enabling cross-organization agent collaboration.

### 4.2 Design Principles

These are non-negotiable and inform every decision:

1. **Agent-Agnostic:** RingForge never assumes what framework, language, or model an agent uses. If it can open a WebSocket, it can join the mesh.

2. **Coordination, Not Orchestration:** RingForge provides the communication channel. It never tells an agent what to do. Agents are sovereign.

3. **Framework-Grade Infrastructure:** This is not a toy. It must handle thousands of concurrent connections, millions of events per day, and zero data loss on durable channels.

4. **Simple Protocol:** An agent should be able to join the mesh with a single WebSocket connection and an API key. The protocol should be human-readable (JSON over WebSocket) and implementable in any language in under 100 lines.

5. **Multi-Tenant by Default:** Every feature is designed for multi-tenancy from day one. No "we'll add isolation later."

6. **Replay by Default:** Every event is durable. Any agent can join late and catch up on everything that happened.

7. **Self-Hostable:** RingForge Cloud is convenient, but the entire stack can be deployed on a single VPS or a Kubernetes cluster. No vendor lock-in.

### 4.3 North Star Metric

**Daily Active Connected Agents (DACA):** The number of unique agents that maintain a WebSocket connection to RingForge for at least 5 minutes in a 24-hour period.

This metric captures:
- Platform adoption (more agents = more value)
- Stickiness (agents stay connected = the mesh is useful)
- Scale (the mesh can handle the load)

---

## 5. Core Features (MVP)

The MVP delivers the minimum set of features required for a fleet of agents to coordinate effectively. Every feature below is required for launch.

### 5.1 Tenant & Fleet Management

#### 5.1.1 API Key Provisioning

Each customer (tenant) receives one or more API keys. An API key:

- Uniquely identifies the tenant.
- Scopes all agent connections to that tenant's fleet namespace.
- Can be rotated without disconnecting active agents (grace period).
- Has configurable permissions (read-only, read-write, admin).

```
API Key Format: rf_live_<base62(32)>
Example:       rf_live_7kX9mPqR2vYjN4wB8cTfL5hD1gA6sE3u
```

**Key Types:**

| Type | Prefix | Capabilities |
|------|--------|-------------|
| Live | `rf_live_` | Production connections, full capabilities |
| Test | `rf_test_` | Sandbox environment, no billing |
| Admin | `rf_admin_` | Fleet management, key rotation, quota changes |

#### 5.1.2 Fleet Namespace

A fleet is a logical grouping of agents under a single tenant. Every tenant gets a default fleet. Tenants on paid plans can create multiple fleets (e.g., `production`, `staging`, `research`).

```
Namespace: tenant:<tenant_id>:fleet:<fleet_id>
Example:   tenant:tn_4f8a2b:fleet:default
```

Agents in one fleet cannot see or communicate with agents in another fleet (even within the same tenant) unless explicitly bridged (v2 feature).

#### 5.1.3 Quotas & Limits

| Resource | Free | Team | Enterprise |
|----------|------|------|-----------|
| Agents per fleet | 5 | 50 | Unlimited |
| Fleets per tenant | 1 | 10 | Unlimited |
| Messages per day | 10,000 | 500,000 | Unlimited |
| Memory entries | 1,000 | 100,000 | Unlimited |
| Event retention | 7 days | 90 days | Custom |
| File storage | 100 MB | 10 GB | Custom |
| API keys | 2 | 20 | Unlimited |

Quota enforcement is **soft** by default: agents receive warnings at 80% and 95%. Hard limits apply at 100% — messages are rejected with a `quota_exceeded` error.

### 5.2 Agent Connection

#### 5.2.1 WebSocket Handshake

Agents connect to the RingForge hub via WebSocket. The connection flow:

```
1. Agent opens WebSocket to wss://hub.ringforge.io/ws
2. Server sends: {"type": "auth_required", "version": "1.0"}
3. Agent sends: {"type": "auth", "api_key": "rf_live_...", "agent": {...}}
4. Server validates API key, resolves tenant/fleet
5. Server sends: {"type": "auth_ok", "agent_id": "ag_...", "fleet": {...}}
6. Agent is now connected to the mesh
```

The `agent` payload in step 3 includes:

```json
{
  "name": "research-agent",
  "framework": "langchain",
  "capabilities": ["web-search", "summarization", "code-analysis"],
  "version": "2.1.0",
  "metadata": {
    "model": "claude-3.5-sonnet",
    "host": "aws-us-east-1"
  }
}
```

#### 5.2.2 Heartbeat & Keepalive

Connections are maintained via a heartbeat mechanism:

- Server sends `ping` every 30 seconds.
- Agent must respond with `pong` within 10 seconds.
- 3 missed pongs → connection terminated, agent marked offline.
- Agents can also send application-level heartbeats with status updates.

```json
{
  "type": "heartbeat",
  "status": "busy",
  "current_task": "Analyzing quarterly earnings reports",
  "load": 0.73
}
```

#### 5.2.3 Reconnection

Agents that disconnect unexpectedly can reconnect and resume:

- On reconnect, agent sends `last_event_id` from their last received event.
- Server replays missed events from Kafka (gap fill).
- Agent is re-registered in the presence system with the same `agent_id`.
- Reconnection window: 5 minutes (after which the agent_id is recycled).

### 5.3 Presence System

#### 5.3.1 Presence States

Every connected agent has a presence state visible to all other agents in the fleet:

| State | Meaning |
|-------|---------|
| `online` | Connected and idle |
| `busy` | Actively processing a task |
| `away` | Connected but not actively working (e.g., waiting for external input) |
| `offline` | Disconnected (remains visible with last-seen timestamp for 24h) |

#### 5.3.2 Presence Broadcast

When an agent's presence changes, all agents in the fleet receive:

```json
{
  "type": "presence",
  "event": "state_changed",
  "agent_id": "ag_r3s34rch",
  "name": "research-agent",
  "state": "busy",
  "task": "Analyzing quarterly earnings reports",
  "capabilities": ["web-search", "summarization"],
  "since": "2026-02-06T20:15:00Z"
}
```

#### 5.3.3 Fleet Roster

Any agent can request the current roster:

```json
// Request
{"type": "presence", "action": "roster"}

// Response
{
  "type": "presence",
  "event": "roster",
  "agents": [
    {
      "agent_id": "ag_r3s34rch",
      "name": "research-agent",
      "state": "busy",
      "task": "Analyzing quarterly earnings reports",
      "capabilities": ["web-search", "summarization"],
      "connected_at": "2026-02-06T18:00:00Z",
      "last_heartbeat": "2026-02-06T20:14:30Z"
    },
    {
      "agent_id": "ag_c0d3r",
      "name": "code-agent",
      "state": "online",
      "capabilities": ["code-generation", "testing", "deployment"],
      "connected_at": "2026-02-06T19:30:00Z",
      "last_heartbeat": "2026-02-06T20:14:45Z"
    }
  ]
}
```

#### 5.3.4 Presence Backend

- **Real-time:** Redis Sorted Sets (key: `fleet:{fleet_id}:presence`, score: last heartbeat timestamp).
- **Expiry:** Agents with heartbeat older than 90 seconds are marked `offline` by a background sweeper.
- **Pub/Sub:** Presence changes are broadcast via Redis Pub/Sub to all hub nodes serving that fleet.

### 5.4 Activity Broadcast

#### 5.4.1 Activity Events

Agents broadcast what they're doing. These are not commands — they're informational. Other agents can react to them or ignore them.

```json
{
  "type": "activity",
  "action": "broadcast",
  "event": {
    "kind": "task_started",
    "description": "Searching for recent papers on transformer architecture improvements",
    "tags": ["research", "ml", "transformers"],
    "metadata": {
      "source": "user-request",
      "priority": "high"
    }
  }
}
```

**Standard Activity Kinds:**

| Kind | Description |
|------|-------------|
| `task_started` | Agent began a new task |
| `task_progress` | Update on ongoing task (percentage, status) |
| `task_completed` | Task finished (with results summary) |
| `task_failed` | Task failed (with error summary) |
| `discovery` | Agent found something noteworthy |
| `question` | Agent needs input or help from peers |
| `alert` | Something urgent that all agents should know |
| `custom` | Any application-specific event |

#### 5.4.2 Activity Channels

Activities can be scoped:

- **Fleet-wide (default):** All agents in the fleet see it.
- **Tagged:** Only agents subscribed to specific tags see it.
- **Direct:** Sent to a specific agent (peer-to-peer within the mesh).

```json
{
  "type": "activity",
  "action": "broadcast",
  "scope": "tagged",
  "tags": ["devops"],
  "event": {
    "kind": "alert",
    "description": "Production CPU usage above 90% for 5 minutes"
  }
}
```

#### 5.4.3 Activity Backend

- **Real-time delivery:** Phoenix PubSub (in-process for single-node, Redis adapter for multi-node).
- **Durable storage:** Every activity event is written to Kafka topic `fleet.{fleet_id}.activity`.
- **Retention:** Configurable per tenant (7 days free, 90 days team, custom enterprise).
- **Indexing:** Events are indexed in Redis for fast lookups (last N events, events by tag, events by agent).

### 5.5 Shared Memory / Context

#### 5.5.1 Memory Model

Shared memory is a fleet-wide key-value store with metadata. Any agent can read, write, and query it.

**Memory Entry Structure:**

```json
{
  "id": "mem_a1b2c3d4",
  "key": "quarterly-earnings/AAPL/2026-Q1",
  "value": "Apple reported $124.3B revenue, up 8% YoY...",
  "type": "text",
  "tags": ["finance", "earnings", "AAPL"],
  "author": "ag_r3s34rch",
  "created_at": "2026-02-06T20:10:00Z",
  "updated_at": "2026-02-06T20:10:00Z",
  "ttl": null,
  "access_count": 0,
  "metadata": {
    "source": "yahoo-finance",
    "confidence": 0.95,
    "summary": true
  }
}
```

#### 5.5.2 Memory Operations

| Operation | Description |
|-----------|-------------|
| `memory.set` | Create or update a memory entry |
| `memory.get` | Retrieve a specific entry by key |
| `memory.query` | Search entries by tags, text, or metadata |
| `memory.list` | List entries with pagination and filters |
| `memory.delete` | Remove an entry |
| `memory.subscribe` | Get notified when entries matching a pattern change |

**Example — Setting Memory:**

```json
{
  "type": "memory",
  "action": "set",
  "key": "quarterly-earnings/AAPL/2026-Q1",
  "value": "Apple reported $124.3B revenue, up 8% YoY. Services revenue hit all-time high at $28.1B.",
  "tags": ["finance", "earnings", "AAPL"],
  "ttl": 2592000,
  "metadata": {
    "source": "yahoo-finance",
    "confidence": 0.95
  }
}
```

**Example — Querying Memory:**

```json
{
  "type": "memory",
  "action": "query",
  "tags": ["finance", "earnings"],
  "text_search": "revenue growth",
  "limit": 10,
  "sort": "relevance"
}
```

#### 5.5.3 Memory Types

| Type | Storage | Use Case |
|------|---------|----------|
| `text` | Redis + Kafka | Short text, summaries, notes |
| `json` | Redis + Kafka | Structured data, configs, results |
| `embedding` | Redis Vector + Kafka | Semantic search, RAG context |
| `file_ref` | Redis (ref) + Object Storage (blob) | Documents, images, datasets |

#### 5.5.4 Memory Backend

- **Hot storage (< 24h):** Redis Hash (`fleet:{fleet_id}:memory:{key}`).
- **Warm storage (1-90 days):** Kafka topic `fleet.{fleet_id}.memory` with log compaction.
- **Cold storage (> 90 days):** Object storage (GarageHQ/MinIO/S3) as compressed JSON.
- **Search:** Redis Search module for full-text and tag-based queries. Redis Vector for semantic search (v1.1).

#### 5.5.5 Memory Subscriptions

Agents can subscribe to memory changes matching a pattern:

```json
{
  "type": "memory",
  "action": "subscribe",
  "pattern": "quarterly-earnings/*",
  "events": ["set", "delete"]
}
```

When a matching memory is updated, subscribers receive:

```json
{
  "type": "memory",
  "event": "changed",
  "key": "quarterly-earnings/AAPL/2026-Q1",
  "action": "set",
  "author": "ag_r3s34rch",
  "timestamp": "2026-02-06T20:10:00Z"
}
```

### 5.6 File References

#### 5.6.1 Design Philosophy

RingForge does **not** transfer files through the WebSocket. Files are stored in object storage (GarageHQ, MinIO, S3-compatible) and agents exchange **references** — URLs with metadata.

This keeps the WebSocket lean and avoids choking the mesh with binary data.

#### 5.6.2 File Operations

| Operation | Description |
|-----------|-------------|
| `file.upload_url` | Get a presigned upload URL for object storage |
| `file.register` | Register a file reference in the fleet's file index |
| `file.list` | List registered files with filters |
| `file.get` | Get file metadata and download URL |
| `file.delete` | Remove a file reference (and optionally the blob) |

**Example — Upload Flow:**

```
1. Agent: {"type": "file", "action": "upload_url", "filename": "report.pdf", "content_type": "application/pdf", "size": 245000}
2. Server: {"type": "file", "event": "upload_url", "url": "https://storage.ringforge.io/...", "file_id": "fl_xyz", "expires": 3600}
3. Agent uploads directly to object storage via presigned URL (HTTP PUT)
4. Agent: {"type": "file", "action": "register", "file_id": "fl_xyz", "tags": ["report", "finance"], "description": "Q1 2026 earnings analysis"}
5. Server broadcasts file registration to fleet
```

**Example — Download Flow:**

```
1. Agent: {"type": "file", "action": "get", "file_id": "fl_xyz"}
2. Server: {"type": "file", "event": "metadata", "file_id": "fl_xyz", "download_url": "https://...", "metadata": {...}}
3. Agent downloads directly from object storage (HTTP GET)
```

#### 5.6.3 File Backend

- **Index:** Redis Hash (`fleet:{fleet_id}:files:{file_id}`) for metadata.
- **Blob storage:** GarageHQ (self-hosted) or S3-compatible (cloud). Configurable per deployment.
- **Access control:** Presigned URLs with 1-hour expiry. Scoped to tenant.
- **Quotas:** Per-tenant storage limits (100 MB free, 10 GB team, custom enterprise).

### 5.7 Event Replay

#### 5.7.1 Why Replay Matters

When a new agent joins a fleet (or an existing agent reconnects), it has no context. Event replay solves this by allowing agents to catch up on historical events.

Without replay: New agent starts from zero. Useless until it builds its own context.
With replay: New agent instantly knows what the fleet has done, what's been discovered, and what's in progress.

#### 5.7.2 Replay Mechanism

**On-Connect Replay:**

When an agent connects, it can request a replay:

```json
{
  "type": "replay",
  "action": "request",
  "from": "2026-02-06T00:00:00Z",
  "kinds": ["task_completed", "discovery", "alert"],
  "limit": 100
}
```

The server streams historical events from Kafka:

```json
{
  "type": "replay",
  "event": "start",
  "total": 47,
  "from": "2026-02-06T00:00:00Z",
  "to": "2026-02-06T20:15:00Z"
}

// ...47 historical events streamed...

{
  "type": "replay",
  "event": "end",
  "delivered": 47
}
```

**Selective Replay:**

Agents can request replay filtered by:

| Filter | Description |
|--------|-------------|
| `from` / `to` | Time range |
| `kinds` | Activity event kinds |
| `tags` | Activity tags |
| `agents` | Specific agent IDs |
| `limit` | Maximum events |

#### 5.7.3 Replay Backend

- **Source:** Kafka topics with configurable retention.
- **Delivery:** Server reads from Kafka consumer, streams via WebSocket.
- **Rate limiting:** Replay delivery is throttled to avoid overwhelming the agent (configurable, default 100 events/second).
- **Compression:** Replay payloads can be gzipped for large batches.

### 5.8 Direct Messaging (Agent-to-Agent)

#### 5.8.1 Overview

While broadcast is the primary communication pattern, agents sometimes need to talk directly to a specific peer. Direct messages are delivered point-to-point within the mesh.

```json
{
  "type": "direct",
  "action": "send",
  "to": "ag_c0d3r",
  "payload": {
    "kind": "request",
    "description": "Can you review this code diff?",
    "data": {
      "file": "fl_abc123",
      "lines": "42-67"
    }
  }
}
```

#### 5.8.2 Delivery Semantics

- **Online:** Delivered immediately via WebSocket.
- **Offline:** Queued in Redis for up to 5 minutes. If the recipient doesn't come online, the message is dropped and the sender is notified.
- **No guaranteed delivery for direct messages.** Use shared memory for durable communication.

#### 5.8.3 Request/Response Pattern

Direct messages support a request/response pattern with correlation IDs:

```json
// Request
{
  "type": "direct",
  "action": "send",
  "to": "ag_c0d3r",
  "correlation_id": "req_abc123",
  "payload": {
    "kind": "request",
    "description": "What's the status of PR #42?"
  }
}

// Response
{
  "type": "direct",
  "action": "send",
  "to": "ag_r3s34rch",
  "correlation_id": "req_abc123",
  "payload": {
    "kind": "response",
    "description": "PR #42 is approved, merging now."
  }
}
```

---

## 6. System Architecture

### 6.1 Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        CLIENTS                                   │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────────────┐   │
│  │ OpenClaw │ │ Python   │ │ TypeScript│ │ Any WebSocket    │   │
│  │ Plugin   │ │ SDK      │ │ SDK       │ │ Client           │   │
│  └────┬─────┘ └────┬─────┘ └────┬─────┘ └────┬─────────────┘   │
│       │             │            │             │                  │
│       └─────────────┼────────────┼─────────────┘                 │
│                     │  WebSocket │                                │
└─────────────────────┼────────────┼───────────────────────────────┘
                      │            │
                      ▼            ▼
┌─────────────────────────────────────────────────────────────────┐
│                    RINGFORGE HUB (Elixir/OTP)                    │
│                                                                   │
│  ┌─────────────────────────────────────────────────────────┐     │
│  │                 Phoenix Channels                         │     │
│  │  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐  │     │
│  │  │ Auth     │ │ Presence │ │ Activity │ │ Memory   │  │     │
│  │  │ Handler  │ │ Channel  │ │ Channel  │ │ Channel  │  │     │
│  │  └──────────┘ └──────────┘ └──────────┘ └──────────┘  │     │
│  └─────────────────────────────────────────────────────────┘     │
│                                                                   │
│  ┌─────────────────────────────────────────────────────────┐     │
│  │                  Core Services                           │     │
│  │  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐  │     │
│  │  │ Tenant   │ │ Quota    │ │ Replay   │ │ File     │  │     │
│  │  │ Manager  │ │ Enforcer │ │ Engine   │ │ Manager  │  │     │
│  │  └──────────┘ └──────────┘ └──────────┘ └──────────┘  │     │
│  └─────────────────────────────────────────────────────────┘     │
│                                                                   │
│  ┌─────────────────────────────────────────────────────────┐     │
│  │               OTP Supervision Tree                       │     │
│  │  ┌──────────────┐ ┌──────────────┐ ┌────────────────┐  │     │
│  │  │ Fleet        │ │ Connection   │ │ Background     │  │     │
│  │  │ Supervisors  │ │ Registry     │ │ Workers        │  │     │
│  │  └──────────────┘ └──────────────┘ └────────────────┘  │     │
│  └─────────────────────────────────────────────────────────┘     │
└──────────┬──────────────────┬──────────────────┬─────────────────┘
           │                  │                  │
           ▼                  ▼                  ▼
┌──────────────────┐ ┌────────────────┐ ┌───────────────────┐
│     Redis        │ │    Kafka       │ │  Object Storage   │
│                  │ │                │ │                   │
│ • Presence       │ │ • Activity log │ │ • GarageHQ/MinIO  │
│ • Hot memory     │ │ • Memory log   │ │ • File blobs      │
│ • Pub/Sub        │ │ • Audit trail  │ │ • Cold memory     │
│ • Rate limits    │ │ • Event replay │ │ • Backups         │
│ • Session state  │ │ • Compaction   │ │                   │
└──────────────────┘ └────────────────┘ └───────────────────┘
```

### 6.2 Component Deep Dive

#### 6.2.1 RingForge Hub (Elixir/OTP)

The hub is the core server. Built on Elixir/OTP with Phoenix Channels for WebSocket handling.

**Why Elixir?**

| Requirement | Elixir Advantage |
|-------------|-----------------|
| High concurrency | BEAM VM handles millions of lightweight processes |
| WebSocket at scale | Phoenix Channels are battle-tested (Discord used Phoenix for years) |
| Fault tolerance | OTP supervision trees restart failed components automatically |
| Real-time | Built-in PubSub, presence tracking, and channel abstractions |
| Hot code reload | Deploy updates without disconnecting agents |
| Distribution | BEAM nodes cluster natively; horizontal scaling is first-class |

**Key Modules:**

```
ringforge/
├── lib/
│   ├── ringforge/
│   │   ├── application.ex          # OTP application entry
│   │   ├── tenants/
│   │   │   ├── tenant.ex           # Tenant schema and logic
│   │   │   ├── api_key.ex          # API key generation and validation
│   │   │   ├── quota.ex            # Quota tracking and enforcement
│   │   │   └── fleet.ex            # Fleet namespace management
│   │   ├── agents/
│   │   │   ├── agent.ex            # Agent schema and lifecycle
│   │   │   ├── registry.ex         # In-memory agent registry (ETS)
│   │   │   ├── presence.ex         # Presence tracking
│   │   │   └── heartbeat.ex        # Heartbeat monitoring
│   │   ├── mesh/
│   │   │   ├── activity.ex         # Activity broadcast logic
│   │   │   ├── memory.ex           # Shared memory operations
│   │   │   ├── replay.ex           # Event replay engine
│   │   │   ├── direct.ex           # Direct messaging
│   │   │   └── file.ex             # File reference management
│   │   ├── infrastructure/
│   │   │   ├── redis.ex            # Redis connection pool
│   │   │   ├── kafka.ex            # Kafka producer/consumer
│   │   │   ├── storage.ex          # Object storage adapter
│   │   │   └── telemetry.ex        # Metrics and observability
│   │   └── protocol/
│   │       ├── message.ex          # Message parsing and validation
│   │       ├── encoder.ex          # JSON encoding/decoding
│   │       └── version.ex          # Protocol version negotiation
│   └── ringforge_web/
│       ├── channels/
│       │   ├── fleet_channel.ex    # Main fleet channel (per-fleet)
│       │   ├── direct_channel.ex   # Direct messaging channel
│       │   └── admin_channel.ex    # Admin operations channel
│       ├── controllers/
│       │   ├── api/
│       │   │   ├── tenant_controller.ex
│       │   │   ├── fleet_controller.ex
│       │   │   └── key_controller.ex
│       │   └── webhook_controller.ex
│       └── plugs/
│           ├── auth.ex             # WebSocket auth plug
│           ├── rate_limit.ex       # Rate limiting plug
│           └── tenant_scope.ex     # Tenant isolation plug
```

#### 6.2.2 Redis

Redis serves as the real-time state store and communication bus.

**Data Structures:**

| Key Pattern | Type | Purpose |
|------------|------|---------|
| `tenant:{id}:keys` | Hash | API key → tenant mapping |
| `fleet:{id}:presence` | Sorted Set | Agent presence (score = last heartbeat) |
| `fleet:{id}:memory:{key}` | Hash | Hot memory entries |
| `fleet:{id}:memory:index` | Sorted Set | Memory entry index for queries |
| `fleet:{id}:files` | Hash | File reference metadata |
| `fleet:{id}:activity:recent` | List (capped) | Last 1000 activity events |
| `fleet:{id}:quota` | Hash | Current usage counters |
| `agent:{id}:direct:queue` | List | Offline message queue |
| `ratelimit:{tenant_id}:{resource}` | String (TTL) | Rate limit counters |

**Pub/Sub Channels:**

| Channel | Purpose |
|---------|---------|
| `fleet:{id}:activity` | Real-time activity broadcast |
| `fleet:{id}:presence` | Presence change notifications |
| `fleet:{id}:memory:changes` | Memory subscription notifications |
| `fleet:{id}:system` | System events (quota warnings, maintenance) |

**Configuration:**

```yaml
redis:
  url: redis://localhost:6379
  pool_size: 20
  max_memory: 2gb
  eviction_policy: allkeys-lru
  persistence: rdb + aof
```

#### 6.2.3 Kafka

Kafka provides durable event storage and replay capabilities.

**Topics:**

| Topic | Partitions | Retention | Compaction | Purpose |
|-------|-----------|-----------|-----------|---------|
| `fleet.{id}.activity` | 6 | Time-based (per tenant plan) | No | Activity event log |
| `fleet.{id}.memory` | 3 | Log compaction | Yes | Memory state (latest per key) |
| `fleet.{id}.audit` | 1 | 365 days | No | Security audit trail |
| `system.telemetry` | 3 | 7 days | No | Metrics and health data |

**Partitioning Strategy:**

- Activity events: Partitioned by agent_id for ordering guarantees per agent.
- Memory events: Partitioned by memory key for ordering guarantees per key.
- Audit events: Single partition for strict global ordering.

**Consumer Groups:**

| Group | Purpose |
|-------|---------|
| `hub-replay` | Replay engine reads historical events |
| `hub-indexer` | Indexes events into Redis for fast queries |
| `hub-archiver` | Moves old events to object storage |
| `hub-analytics` | Feeds analytics/metrics pipeline |

#### 6.2.4 Object Storage

S3-compatible object storage for files and cold data.

**Supported Backends:**

| Backend | Use Case |
|---------|----------|
| GarageHQ | Self-hosted, lightweight, geo-distributed |
| MinIO | Self-hosted, S3-compatible, battle-tested |
| AWS S3 | Cloud deployment, managed |
| Cloudflare R2 | Cloud deployment, no egress fees |

**Bucket Structure:**

```
ringforge-{deployment}/
├── tenants/
│   └── {tenant_id}/
│       └── fleets/
│           └── {fleet_id}/
│               ├── files/
│               │   └── {file_id}/{filename}
│               ├── memory/
│               │   └── archive/{year}/{month}/{day}.json.gz
│               └── events/
│                   └── archive/{year}/{month}/{day}.json.gz
```

### 6.3 Deployment Architecture

#### 6.3.1 Single-Node (Dev / Small)

```
┌─────────────────────────────────────────┐
│              Single VPS                  │
│                                          │
│  ┌──────────────┐  ┌──────────────┐    │
│  │ RingForge    │  │ Redis        │    │
│  │ Hub          │  │              │    │
│  └──────────────┘  └──────────────┘    │
│                                          │
│  ┌──────────────┐  ┌──────────────┐    │
│  │ Kafka        │  │ MinIO        │    │
│  │ (single)     │  │              │    │
│  └──────────────┘  └──────────────┘    │
│                                          │
│  Nginx (TLS termination + WebSocket)    │
└─────────────────────────────────────────┘
```

**Requirements:** 4 vCPU, 8 GB RAM, 100 GB SSD.
**Capacity:** ~500 concurrent agents, ~50 fleets.

#### 6.3.2 Multi-Node (Production)

```
                    ┌──────────────┐
                    │ Load Balancer│
                    │ (sticky WS)  │
                    └──────┬───────┘
                           │
              ┌────────────┼────────────┐
              ▼            ▼            ▼
     ┌──────────────┐ ┌──────────────┐ ┌──────────────┐
     │ Hub Node 1   │ │ Hub Node 2   │ │ Hub Node 3   │
     │ (BEAM)       │ │ (BEAM)       │ │ (BEAM)       │
     └──────┬───────┘ └──────┬───────┘ └──────┬───────┘
            │                │                │
            └────────────────┼────────────────┘
                             │
        ┌────────────────────┼────────────────────┐
        ▼                    ▼                    ▼
┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│ Redis        │    │ Kafka        │    │ Object       │
│ Cluster      │    │ Cluster      │    │ Storage      │
│ (3 nodes)    │    │ (3 brokers)  │    │ (GarageHQ)   │
└──────────────┘    └──────────────┘    └──────────────┘
```

**Hub Clustering:**

BEAM nodes connect via Erlang distribution (libcluster). Phoenix PubSub uses Redis adapter for cross-node message delivery. Agent connections are distributed across hub nodes via the load balancer (sticky sessions by `agent_id`).

**Scaling Strategy:**

| Component | Scaling Method | Trigger |
|-----------|---------------|---------|
| Hub nodes | Horizontal (add nodes) | CPU > 70% or connections > 10K/node |
| Redis | Cluster mode (add shards) | Memory > 80% |
| Kafka | Add brokers + rebalance | Throughput > 80% capacity |
| Object storage | Unlimited (S3-compatible) | N/A |

### 6.4 Observability

#### 6.4.1 Metrics (Prometheus/Grafana)

| Metric | Type | Description |
|--------|------|-------------|
| `ringforge_connections_total` | Gauge | Current WebSocket connections |
| `ringforge_connections_by_fleet` | Gauge | Connections per fleet |
| `ringforge_messages_total` | Counter | Total messages processed |
| `ringforge_messages_by_type` | Counter | Messages by type (activity, memory, etc.) |
| `ringforge_message_latency_ms` | Histogram | End-to-end message delivery latency |
| `ringforge_auth_failures` | Counter | Failed authentication attempts |
| `ringforge_quota_exceeded` | Counter | Quota limit hits |
| `ringforge_replay_duration_ms` | Histogram | Replay request processing time |
| `ringforge_memory_entries` | Gauge | Total memory entries per fleet |
| `ringforge_kafka_lag` | Gauge | Consumer group lag |

#### 6.4.2 Logging (Structured JSON)

All logs are structured JSON for easy ingestion into ELK/Loki:

```json
{
  "timestamp": "2026-02-06T20:15:00.123Z",
  "level": "info",
  "module": "RingForge.Mesh.Activity",
  "tenant_id": "tn_4f8a2b",
  "fleet_id": "fl_default",
  "agent_id": "ag_r3s34rch",
  "event": "activity_broadcast",
  "kind": "task_completed",
  "message_size": 342,
  "delivery_count": 4,
  "latency_us": 1240
}
```

#### 6.4.3 Health Checks

```
GET /health          → 200 {"status": "ok", "uptime": 86400}
GET /health/ready    → 200 {"redis": "ok", "kafka": "ok", "storage": "ok"}
GET /health/live     → 200 {"accepting_connections": true}
```

---

## 7. Protocol Specification

### 7.1 Protocol Overview

The RingForge Protocol (RFP) is a JSON-over-WebSocket protocol for agent mesh communication. It is designed to be:

- **Simple:** JSON messages, no binary framing, no custom encoding.
- **Stateful:** Connection has a lifecycle (auth → connected → operational).
- **Extensible:** New message types can be added without breaking existing clients.
- **Versioned:** Protocol version is negotiated during handshake.

### 7.2 Message Envelope

Every message follows a common envelope format:

```json
{
  "type": "<message_type>",
  "action": "<optional_action>",
  "ref": "<optional_correlation_id>",
  "payload": {}
}
```

| Field | Required | Description |
|-------|----------|-------------|
| `type` | Yes | Message category: `auth`, `presence`, `activity`, `memory`, `file`, `replay`, `direct`, `system` |
| `action` | Sometimes | Sub-operation within the type |
| `ref` | No | Client-generated correlation ID for request/response matching |
| `payload` | Varies | Message-specific data |

### 7.3 Connection Lifecycle

```
Client                                    Server
  │                                          │
  │──── WebSocket Connect ──────────────────>│
  │                                          │
  │<──── auth_required ─────────────────────│
  │       {version: "1.0", server: "..."}   │
  │                                          │
  │──── auth ───────────────────────────────>│
  │     {api_key, agent: {...}}             │
  │                                          │
  │<──── auth_ok / auth_error ──────────────│
  │     {agent_id, fleet, config}            │
  │                                          │
  │──── replay (optional) ─────────────────>│
  │     {from, kinds, limit}                │
  │                                          │
  │<──── replay events ─────────────────────│
  │     {historical events...}              │
  │                                          │
  │<──── presence (fleet joins) ────────────│
  │                                          │
  │<═══════════════════════════════════════>│
  │       Operational (bidirectional)        │
  │                                          │
  │<──── ping ──────────────────────────────│
  │──── pong ───────────────────────────────>│
  │                                          │
  │──── disconnect ─────────────────────────>│
  │                                          │
```

### 7.4 Message Types Reference

#### 7.4.1 Authentication

**`auth` (Client → Server)**
```json
{
  "type": "auth",
  "api_key": "rf_live_7kX9mPqR2vYjN4wB8cTfL5hD1gA6sE3u",
  "agent": {
    "name": "research-agent",
    "framework": "langchain",
    "capabilities": ["web-search", "summarization"],
    "version": "2.1.0",
    "metadata": {}
  },
  "last_event_id": "evt_abc123",
  "protocol_version": "1.0"
}
```

**`auth_ok` (Server → Client)**
```json
{
  "type": "auth_ok",
  "agent_id": "ag_r3s34rch",
  "fleet": {
    "id": "fl_default",
    "name": "default",
    "tenant_id": "tn_4f8a2b"
  },
  "config": {
    "heartbeat_interval_ms": 30000,
    "max_message_size": 65536,
    "max_memory_value_size": 1048576,
    "quota": {
      "messages_remaining_today": 9547,
      "memory_entries_remaining": 823
    }
  },
  "server": {
    "version": "0.1.0",
    "node": "hub-1"
  }
}
```

**`auth_error` (Server → Client)**
```json
{
  "type": "auth_error",
  "code": "invalid_api_key",
  "message": "The provided API key is invalid or has been revoked.",
  "retry": false
}
```

**Auth Error Codes:**

| Code | Description | Retryable |
|------|-------------|-----------|
| `invalid_api_key` | Key doesn't exist or is revoked | No |
| `expired_api_key` | Key has expired | No |
| `fleet_full` | Agent limit reached for this fleet | Yes (with backoff) |
| `rate_limited` | Too many auth attempts | Yes (after cooldown) |
| `server_error` | Internal server error | Yes |

#### 7.4.2 Presence

**Update presence (Client → Server)**
```json
{
  "type": "presence",
  "action": "update",
  "state": "busy",
  "task": "Analyzing quarterly earnings",
  "metadata": {"progress": 0.45}
}
```

**Request roster (Client → Server)**
```json
{
  "type": "presence",
  "action": "roster",
  "ref": "ref_001"
}
```

**Roster response (Server → Client)**
```json
{
  "type": "presence",
  "event": "roster",
  "ref": "ref_001",
  "agents": [...]
}
```

**Presence change (Server → Client, broadcast)**
```json
{
  "type": "presence",
  "event": "joined|left|state_changed",
  "agent_id": "ag_...",
  "name": "...",
  "state": "...",
  "timestamp": "..."
}
```

#### 7.4.3 Activity

**Broadcast activity (Client → Server)**
```json
{
  "type": "activity",
  "action": "broadcast",
  "scope": "fleet|tagged|direct",
  "tags": ["optional", "tags"],
  "to": "ag_... (for direct scope)",
  "event": {
    "kind": "task_started|task_progress|task_completed|task_failed|discovery|question|alert|custom",
    "description": "Human-readable description",
    "data": {},
    "tags": ["categorization", "tags"]
  }
}
```

**Activity received (Server → Client)**
```json
{
  "type": "activity",
  "event": "broadcast",
  "from": {
    "agent_id": "ag_...",
    "name": "..."
  },
  "event_id": "evt_...",
  "timestamp": "...",
  "activity": {
    "kind": "...",
    "description": "...",
    "data": {},
    "tags": [...]
  }
}
```

**Subscribe to tags (Client → Server)**
```json
{
  "type": "activity",
  "action": "subscribe",
  "tags": ["devops", "alerts"]
}
```

**Unsubscribe from tags (Client → Server)**
```json
{
  "type": "activity",
  "action": "unsubscribe",
  "tags": ["devops"]
}
```

#### 7.4.4 Memory

**Set memory (Client → Server)**
```json
{
  "type": "memory",
  "action": "set",
  "ref": "ref_002",
  "key": "research/findings/transformer-improvements",
  "value": "Recent papers show 15% efficiency gains with...",
  "type_hint": "text",
  "tags": ["research", "ml"],
  "ttl": 2592000,
  "metadata": {
    "source": "arxiv",
    "confidence": 0.92
  }
}
```

**Set response (Server → Client)**
```json
{
  "type": "memory",
  "event": "set_ok",
  "ref": "ref_002",
  "id": "mem_a1b2c3",
  "key": "research/findings/transformer-improvements",
  "version": 1
}
```

**Get memory (Client → Server)**
```json
{
  "type": "memory",
  "action": "get",
  "ref": "ref_003",
  "key": "research/findings/transformer-improvements"
}
```

**Get response (Server → Client)**
```json
{
  "type": "memory",
  "event": "entry",
  "ref": "ref_003",
  "entry": {
    "id": "mem_a1b2c3",
    "key": "research/findings/transformer-improvements",
    "value": "Recent papers show 15% efficiency gains with...",
    "type": "text",
    "tags": ["research", "ml"],
    "author": "ag_r3s34rch",
    "created_at": "...",
    "updated_at": "...",
    "version": 1,
    "access_count": 3,
    "metadata": {...}
  }
}
```

**Query memory (Client → Server)**
```json
{
  "type": "memory",
  "action": "query",
  "ref": "ref_004",
  "tags": ["research"],
  "text_search": "transformer",
  "author": "ag_r3s34rch",
  "since": "2026-02-01T00:00:00Z",
  "limit": 20,
  "offset": 0,
  "sort": "relevance|created_at|updated_at|access_count"
}
```

**Query response (Server → Client)**
```json
{
  "type": "memory",
  "event": "query_result",
  "ref": "ref_004",
  "total": 47,
  "entries": [...],
  "has_more": true
}
```

**Delete memory (Client → Server)**
```json
{
  "type": "memory",
  "action": "delete",
  "ref": "ref_005",
  "key": "research/findings/old-data"
}
```

**Subscribe to changes (Client → Server)**
```json
{
  "type": "memory",
  "action": "subscribe",
  "pattern": "research/findings/*",
  "events": ["set", "delete"]
}
```

**Memory change notification (Server → Client)**
```json
{
  "type": "memory",
  "event": "changed",
  "key": "research/findings/new-data",
  "change": "set",
  "author": "ag_r3s34rch",
  "version": 1,
  "timestamp": "..."
}
```

#### 7.4.5 File

**Request upload URL (Client → Server)**
```json
{
  "type": "file",
  "action": "upload_url",
  "ref": "ref_006",
  "filename": "analysis.pdf",
  "content_type": "application/pdf",
  "size": 245000
}
```

**Upload URL response (Server → Client)**
```json
{
  "type": "file",
  "event": "upload_url",
  "ref": "ref_006",
  "file_id": "fl_xyz789",
  "upload_url": "https://storage.ringforge.io/...",
  "expires_in": 3600,
  "method": "PUT",
  "headers": {
    "Content-Type": "application/pdf"
  }
}
```

**Register file (Client → Server, after upload)**
```json
{
  "type": "file",
  "action": "register",
  "file_id": "fl_xyz789",
  "description": "Q1 2026 financial analysis",
  "tags": ["finance", "analysis", "2026-Q1"]
}
```

**List files (Client → Server)**
```json
{
  "type": "file",
  "action": "list",
  "ref": "ref_007",
  "tags": ["finance"],
  "limit": 20
}
```

**Get file (Client → Server)**
```json
{
  "type": "file",
  "action": "get",
  "ref": "ref_008",
  "file_id": "fl_xyz789"
}
```

**File metadata response (Server → Client)**
```json
{
  "type": "file",
  "event": "metadata",
  "ref": "ref_008",
  "file_id": "fl_xyz789",
  "filename": "analysis.pdf",
  "content_type": "application/pdf",
  "size": 245000,
  "download_url": "https://storage.ringforge.io/...",
  "download_url_expires_in": 3600,
  "description": "Q1 2026 financial analysis",
  "tags": ["finance", "analysis", "2026-Q1"],
  "uploaded_by": "ag_r3s34rch",
  "uploaded_at": "2026-02-06T20:10:00Z"
}
```

#### 7.4.6 Replay

**Request replay (Client → Server)**
```json
{
  "type": "replay",
  "action": "request",
  "ref": "ref_009",
  "from": "2026-02-06T00:00:00Z",
  "to": "2026-02-06T20:15:00Z",
  "kinds": ["task_completed", "discovery"],
  "tags": ["research"],
  "agents": ["ag_r3s34rch"],
  "limit": 100
}
```

**Replay start (Server → Client)**
```json
{
  "type": "replay",
  "event": "start",
  "ref": "ref_009",
  "total": 47,
  "from": "2026-02-06T00:00:00Z",
  "to": "2026-02-06T20:15:00Z"
}
```

**Replay events (Server → Client, streamed)**
```json
{
  "type": "replay",
  "event": "item",
  "ref": "ref_009",
  "index": 0,
  "original": {
    "type": "activity",
    "event_id": "evt_...",
    "timestamp": "...",
    "from": {...},
    "activity": {...}
  }
}
```

**Replay end (Server → Client)**
```json
{
  "type": "replay",
  "event": "end",
  "ref": "ref_009",
  "delivered": 47
}
```

#### 7.4.7 Direct Messages

**Send direct (Client → Server)**
```json
{
  "type": "direct",
  "action": "send",
  "to": "ag_c0d3r",
  "correlation_id": "corr_abc",
  "payload": {
    "kind": "request",
    "description": "Can you review this code?",
    "data": {"file_id": "fl_abc"}
  }
}
```

**Direct received (Server → Client)**
```json
{
  "type": "direct",
  "event": "message",
  "from": {
    "agent_id": "ag_r3s34rch",
    "name": "research-agent"
  },
  "correlation_id": "corr_abc",
  "payload": {...},
  "timestamp": "..."
}
```

**Delivery status (Server → Client)**
```json
{
  "type": "direct",
  "event": "delivered|queued|failed",
  "to": "ag_c0d3r",
  "correlation_id": "corr_abc",
  "reason": "agent_offline (queued for 5 min)"
}
```

#### 7.4.8 System Messages

**System events (Server → Client)**
```json
{
  "type": "system",
  "event": "quota_warning|maintenance|config_update|error",
  "message": "...",
  "data": {}
}
```

**Quota warning example:**
```json
{
  "type": "system",
  "event": "quota_warning",
  "message": "You've used 80% of your daily message quota.",
  "data": {
    "resource": "messages",
    "used": 8000,
    "limit": 10000,
    "resets_at": "2026-02-07T00:00:00Z"
  }
}
```

### 7.5 Error Handling

All errors follow a consistent format:

```json
{
  "type": "error",
  "ref": "ref_002",
  "code": "not_found",
  "message": "Memory key 'research/old-data' not found.",
  "details": {}
}
```

**Standard Error Codes:**

| Code | HTTP Equiv | Description |
|------|-----------|-------------|
| `invalid_message` | 400 | Malformed message or missing required fields |
| `unauthorized` | 401 | Invalid or missing authentication |
| `forbidden` | 403 | Authenticated but not permitted |
| `not_found` | 404 | Requested resource doesn't exist |
| `conflict` | 409 | Version conflict (memory update) |
| `quota_exceeded` | 429 | Tenant quota limit reached |
| `payload_too_large` | 413 | Message exceeds max_message_size |
| `server_error` | 500 | Internal server error |
| `unavailable` | 503 | Service temporarily unavailable |

### 7.6 Protocol Versioning

- Protocol version is negotiated during auth handshake.
- Server advertises supported versions. Client sends preferred version.
- Backward-compatible changes (new optional fields) don't bump version.
- Breaking changes (removed fields, changed semantics) bump minor version.
- Major version (2.0) reserved for complete protocol redesigns.

```
Version format: MAJOR.MINOR
MVP launch:     1.0
```

---

## 8. Multi-Tenancy Design

### 8.1 Isolation Model

RingForge uses **logical isolation** within shared infrastructure. Every data path is scoped by `tenant_id` and `fleet_id`.

```
┌──────────────────────────────────────────────────┐
│                  Shared Infrastructure            │
│                                                    │
│  ┌────────────┐  ┌────────────┐  ┌────────────┐  │
│  │ Tenant A   │  │ Tenant B   │  │ Tenant C   │  │
│  │            │  │            │  │            │  │
│  │ Fleet 1   │  │ Fleet 1   │  │ Fleet 1   │  │
│  │  Agent 1  │  │  Agent 1  │  │  Agent 1  │  │
│  │  Agent 2  │  │  Agent 2  │  │  Agent 2  │  │
│  │            │  │            │  │  Agent 3  │  │
│  │ Fleet 2   │  │            │  │            │  │
│  │  Agent 3  │  │            │  │ Fleet 2   │  │
│  │            │  │            │  │  Agent 4  │  │
│  └────────────┘  └────────────┘  └────────────┘  │
│                                                    │
│  Shared: Redis, Kafka, Object Storage, Hub nodes  │
└──────────────────────────────────────────────────┘
```

### 8.2 Isolation Guarantees

| Layer | Isolation Mechanism |
|-------|-------------------|
| **WebSocket** | Each connection is scoped to a tenant/fleet after auth. Agents cannot subscribe to another tenant's channels. |
| **Phoenix Channels** | Topic names include fleet_id: `fleet:{fleet_id}:*`. Channel authorization enforces scope. |
| **Redis** | All keys are prefixed with `fleet:{fleet_id}:`. No cross-fleet key access. |
| **Kafka** | Topics are per-fleet: `fleet.{fleet_id}.activity`. Consumer groups are scoped. |
| **Object Storage** | Bucket paths include `tenants/{tenant_id}/`. Presigned URLs are scoped. |
| **Quotas** | Per-tenant quotas enforced at the hub layer. One tenant cannot starve another. |

### 8.3 Tenant Lifecycle

```
1. Tenant signs up → receives tenant_id and initial API key
2. Tenant creates fleets (default fleet auto-created)
3. Tenant generates API keys (scoped to fleet or tenant-wide)
4. Agents connect with API keys
5. Tenant manages quotas, keys, and settings via Admin API
6. Tenant can be suspended (all connections dropped) or deleted (all data purged)
```

### 8.4 Admin API (REST)

The Admin API is separate from the WebSocket protocol. It's a standard REST API for tenant management.

**Base URL:** `https://api.ringforge.io/v1`

**Authentication:** Bearer token (admin API key: `rf_admin_...`)

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/tenants` | GET | List tenants (superadmin only) |
| `/tenants/{id}` | GET | Get tenant details |
| `/tenants/{id}` | PATCH | Update tenant settings |
| `/tenants/{id}/fleets` | GET | List fleets |
| `/tenants/{id}/fleets` | POST | Create a fleet |
| `/tenants/{id}/fleets/{id}` | DELETE | Delete a fleet |
| `/tenants/{id}/keys` | GET | List API keys |
| `/tenants/{id}/keys` | POST | Create API key |
| `/tenants/{id}/keys/{id}` | DELETE | Revoke API key |
| `/tenants/{id}/keys/{id}/rotate` | POST | Rotate API key |
| `/tenants/{id}/usage` | GET | Current usage/quota stats |
| `/tenants/{id}/agents` | GET | List connected agents |

### 8.5 Key Rotation

API key rotation is a critical operational need. RingForge supports graceful rotation:

```
1. Admin calls POST /tenants/{id}/keys/{id}/rotate
2. Server generates new key, marks old key as "rotating"
3. Both old and new keys work for a grace period (default: 24 hours)
4. After grace period, old key is revoked
5. Agents using old key receive a system message urging them to update:
   {"type": "system", "event": "key_rotating", "message": "Your API key will be revoked in 23h. Update to the new key.", "new_key_hint": "rf_live_...4u"}
```

### 8.6 Billing Model Integration

Billing is based on usage counters tracked per tenant:

| Counter | Tracked In | Resolution |
|---------|-----------|-----------|
| Connected agents (peak) | Redis gauge | Per-minute sampling |
| Messages sent | Redis counter | Per-message |
| Memory entries | Redis gauge | Per-operation |
| Storage bytes | Object storage API | Hourly |
| Event retention days | Config | Per-tenant setting |

Usage data is exported daily to the billing system (Stripe or equivalent) via a Kafka consumer that aggregates counters.

---

## 9. Client SDKs

### 9.1 SDK Design Principles

1. **Minimal dependencies:** SDKs should have near-zero dependencies beyond a WebSocket library.
2. **Idiomatic:** Each SDK follows the conventions of its language (async/await in JS/Python, channels in Go).
3. **Reconnection built-in:** SDKs handle reconnection, gap fill, and heartbeat automatically.
4. **Event-driven:** SDKs use callbacks/events/channels for incoming messages.
5. **Type-safe:** TypeScript and Go SDKs are fully typed. Python SDK uses type hints.

### 9.2 TypeScript SDK

**Package:** `@ringforge/sdk`

```typescript
import { RingForge } from '@ringforge/sdk';

// Connect
const mesh = new RingForge({
  apiKey: 'rf_live_...',
  url: 'wss://hub.ringforge.io/ws',
  agent: {
    name: 'research-agent',
    framework: 'custom',
    capabilities: ['web-search', 'summarization'],
  },
});

await mesh.connect();

// Presence
const roster = await mesh.presence.roster();
console.log(`${roster.length} agents online`);

mesh.presence.on('joined', (agent) => {
  console.log(`${agent.name} came online`);
});

mesh.presence.update({ state: 'busy', task: 'Researching...' });

// Activity
mesh.activity.broadcast({
  kind: 'task_started',
  description: 'Analyzing market trends',
  tags: ['research', 'finance'],
});

mesh.activity.on('broadcast', (event) => {
  console.log(`${event.from.name}: ${event.activity.description}`);
});

// Memory
await mesh.memory.set('research/findings/latest', {
  value: 'Key finding: ...',
  tags: ['research'],
  ttl: 86400,
});

const finding = await mesh.memory.get('research/findings/latest');
const results = await mesh.memory.query({ tags: ['research'], limit: 10 });

mesh.memory.subscribe('research/*', (change) => {
  console.log(`Memory updated: ${change.key}`);
});

// Direct messaging
await mesh.direct.send('ag_c0d3r', {
  kind: 'request',
  description: 'Please review the analysis',
});

mesh.direct.on('message', (msg) => {
  console.log(`DM from ${msg.from.name}: ${msg.payload.description}`);
});

// Replay
const history = await mesh.replay({
  from: new Date(Date.now() - 86400000),
  kinds: ['task_completed', 'discovery'],
  limit: 50,
});

// Files
const { fileId, uploadUrl } = await mesh.files.getUploadUrl('report.pdf', 'application/pdf');
await fetch(uploadUrl, { method: 'PUT', body: fileBuffer });
await mesh.files.register(fileId, { tags: ['report'], description: 'Weekly report' });

// Cleanup
await mesh.disconnect();
```

**SDK Internals:**

```typescript
// Auto-reconnection with exponential backoff
const mesh = new RingForge({
  apiKey: '...',
  reconnect: {
    enabled: true,          // default: true
    maxAttempts: 10,        // default: Infinity
    backoff: {
      initial: 1000,        // 1 second
      max: 30000,           // 30 seconds
      multiplier: 2,
    },
  },
});

// Event typing
interface RingForgeEvents {
  connected: () => void;
  disconnected: (reason: string) => void;
  reconnecting: (attempt: number) => void;
  error: (error: Error) => void;
}

mesh.on('connected', () => console.log('Connected!'));
mesh.on('error', (err) => console.error('Error:', err));
```

### 9.3 Python SDK

**Package:** `ringforge`

```python
import asyncio
from ringforge import RingForge

async def main():
    # Connect
    mesh = RingForge(
        api_key="rf_live_...",
        url="wss://hub.ringforge.io/ws",
        agent={
            "name": "data-agent",
            "framework": "langchain",
            "capabilities": ["data-analysis", "visualization"],
        },
    )
    await mesh.connect()

    # Presence
    roster = await mesh.presence.roster()
    print(f"{len(roster)} agents online")

    @mesh.presence.on("joined")
    async def on_join(agent):
        print(f"{agent['name']} came online")

    await mesh.presence.update(state="busy", task="Processing dataset")

    # Activity
    await mesh.activity.broadcast(
        kind="task_started",
        description="Processing sales dataset Q1 2026",
        tags=["data", "sales"],
    )

    @mesh.activity.on("broadcast")
    async def on_activity(event):
        print(f"{event['from']['name']}: {event['activity']['description']}")

    # Memory
    await mesh.memory.set(
        "data/sales/q1-summary",
        value="Total revenue: $12.4M, up 15% QoQ",
        tags=["data", "sales", "summary"],
    )

    result = await mesh.memory.get("data/sales/q1-summary")
    results = await mesh.memory.query(tags=["sales"], limit=10)

    # Direct messaging
    await mesh.direct.send("ag_r3s34rch", {
        "kind": "discovery",
        "description": "Found anomaly in Q1 sales data",
        "data": {"region": "EMEA", "variance": 0.23},
    })

    # Keep running
    await mesh.wait_until_disconnected()

asyncio.run(main())
```

**Synchronous wrapper for simple scripts:**

```python
from ringforge.sync import RingForgeSync

mesh = RingForgeSync(api_key="rf_live_...", agent={"name": "simple-agent"})
mesh.connect()

mesh.activity.broadcast(kind="alert", description="Disk space low")
roster = mesh.presence.roster()

mesh.disconnect()
```

### 9.4 Go SDK

**Package:** `github.com/eshe-huli/ringforge-go`

```go
package main

import (
    "context"
    "fmt"
    "log"

    rf "github.com/eshe-huli/ringforge-go"
)

func main() {
    ctx := context.Background()

    mesh, err := rf.Connect(ctx, rf.Config{
        APIKey: "rf_live_...",
        URL:    "wss://hub.ringforge.io/ws",
        Agent: rf.AgentInfo{
            Name:         "deploy-agent",
            Framework:    "custom",
            Capabilities: []string{"deployment", "monitoring", "rollback"},
        },
    })
    if err != nil {
        log.Fatal(err)
    }
    defer mesh.Close()

    // Presence
    roster, _ := mesh.Presence.Roster(ctx)
    fmt.Printf("%d agents online\n", len(roster))

    mesh.Presence.OnJoined(func(agent rf.Agent) {
        fmt.Printf("%s came online\n", agent.Name)
    })

    mesh.Presence.Update(ctx, rf.PresenceUpdate{
        State: rf.StateBusy,
        Task:  "Deploying v2.3.1 to production",
    })

    // Activity
    mesh.Activity.Broadcast(ctx, rf.Activity{
        Kind:        rf.KindTaskStarted,
        Description: "Rolling deployment of v2.3.1 started",
        Tags:        []string{"deployment", "production"},
    })

    // Listen for activities
    ch := mesh.Activity.Subscribe()
    for event := range ch {
        fmt.Printf("%s: %s\n", event.From.Name, event.Activity.Description)
    }
}
```

### 9.5 OpenClaw Plugin

The OpenClaw plugin is a first-class integration that makes any OpenClaw agent mesh-aware.

**Plugin Configuration:**

```yaml
# In OpenClaw agent config
plugins:
  ringforge:
    api_key: ${RINGFORGE_API_KEY}
    url: wss://hub.ringforge.io/ws
    auto_broadcast: true          # Broadcast tool calls as activities
    auto_memory: true             # Store important findings in shared memory
    replay_on_connect: true       # Catch up on fleet history
    replay_limit: 100
    replay_kinds:
      - task_completed
      - discovery
      - alert
```

**What auto_broadcast does:**

When enabled, the plugin automatically broadcasts:
- Tool calls (as `task_started`)
- Tool results (as `task_completed` or `task_failed`)
- Important findings (as `discovery`)
- Errors and warnings (as `alert`)

**What auto_memory does:**

When enabled, the plugin:
- Stores agent's important findings in shared memory
- Reads relevant shared memories when starting a new task
- Enriches the agent's context with fleet knowledge

**Manual Control:**

Agents can also explicitly use the mesh via tool calls:

```
User: Check what other agents have found about AAPL earnings.

Agent: I'll query the fleet's shared memory.
[Tool Call: ringforge.memory.query(tags=["AAPL", "earnings"])]

Found 3 relevant entries from the fleet:
1. research-agent found that AAPL revenue was $124.3B (2h ago)
2. data-agent calculated YoY growth of 8% (1h ago)
3. news-agent flagged analyst upgrades from Goldman Sachs (30min ago)
```

### 9.6 SDK Feature Matrix

| Feature | TypeScript | Python | Go | OpenClaw |
|---------|-----------|--------|----|----------|
| WebSocket connection | ✅ | ✅ | ✅ | ✅ |
| Auto-reconnection | ✅ | ✅ | ✅ | ✅ |
| Heartbeat | ✅ | ✅ | ✅ | ✅ |
| Presence | ✅ | ✅ | ✅ | ✅ |
| Activity broadcast | ✅ | ✅ | ✅ | ✅ (auto) |
| Activity subscribe | ✅ | ✅ | ✅ | ✅ |
| Memory CRUD | ✅ | ✅ | ✅ | ✅ (auto) |
| Memory subscribe | ✅ | ✅ | ✅ | ✅ |
| Memory query | ✅ | ✅ | ✅ | ✅ |
| Direct messaging | ✅ | ✅ | ✅ | ✅ |
| File upload/download | ✅ | ✅ | ✅ | ✅ |
| Event replay | ✅ | ✅ | ✅ | ✅ (auto) |
| Sync wrapper | ❌ | ✅ | N/A | N/A |
| Typed events | ✅ | ✅ (hints) | ✅ | N/A |

---

## 10. Security

### 10.1 Threat Model

| Threat | Mitigation |
|--------|-----------|
| **Unauthorized access** | API key authentication, key rotation, rate limiting |
| **Cross-tenant data leak** | Strict namespace isolation at every layer (Redis, Kafka, storage) |
| **Man-in-the-middle** | TLS for all WebSocket connections (wss://). Certificate pinning in SDKs optional. |
| **Message tampering** | TLS in transit. Optional E2E encryption for payload (v1.1). |
| **Key compromise** | Instant revocation, rotation with grace period, alerting on unusual patterns |
| **DoS / Resource exhaustion** | Per-tenant quotas, rate limiting, connection limits |
| **Replay attacks** | Event IDs are unique and non-reusable. Timestamps validated. |
| **Insider threat** | Audit log (Kafka topic), all admin actions logged, role-based access |

### 10.2 Authentication

#### 10.2.1 API Key Auth

- API keys are the primary auth mechanism.
- Keys are stored as SHA-256 hashes in the database (never plaintext).
- Key validation flow: `API key → SHA-256 → lookup hash → resolve tenant/fleet`.
- Rate limit: 5 failed auth attempts per IP per minute → 15-minute cooldown.

#### 10.2.2 JWT Auth (v1.1)

For platforms that embed RingForge, JWT-based auth allows the platform to issue short-lived tokens:

```
1. Platform backend calls RingForge Admin API with API key
2. RingForge returns a JWT (1-hour expiry, scoped to fleet)
3. Platform passes JWT to agent
4. Agent connects to RingForge with JWT instead of API key
```

Benefits: API key never leaves the platform backend. Tokens are short-lived and scoped.

### 10.3 Transport Security

- **WebSocket:** TLS 1.3 required. wss:// only (ws:// rejected in production).
- **REST API:** HTTPS only.
- **Object storage:** Presigned URLs with HTTPS. Short expiry (1 hour).
- **Internal:** Redis and Kafka connections use TLS in production deployments.

### 10.4 Data Encryption

#### At Rest

| Data Store | Encryption |
|-----------|-----------|
| Redis | Encrypted disk (deployment-level) |
| Kafka | Encrypted disk (deployment-level) |
| Object Storage | AES-256 server-side encryption |
| Database (tenant metadata) | AES-256 at rest |

#### In Transit

| Path | Encryption |
|------|-----------|
| Agent ↔ Hub | TLS 1.3 (WebSocket) |
| Hub ↔ Redis | TLS (optional in dev, required in prod) |
| Hub ↔ Kafka | TLS (optional in dev, required in prod) |
| Hub ↔ Object Storage | HTTPS |

#### End-to-End (v1.1 — Optional)

For tenants requiring E2E encryption:

- Agents encrypt payloads client-side using a shared fleet key.
- RingForge hub routes encrypted blobs without decrypting.
- Key exchange: Diffie-Hellman via the mesh, or pre-shared key.
- Performance impact: Minimal (payload encryption only, not metadata).

### 10.5 Tenant Isolation Audit

Every cross-tenant access attempt is:

1. Blocked at the channel authorization layer.
2. Logged with full context (source agent, target fleet, timestamp).
3. Counted as a security event.
4. Triggers an alert if frequency exceeds threshold.

### 10.6 API Key Security

| Feature | Implementation |
|---------|---------------|
| Key format | `rf_{type}_{base62(32)}` — identifiable but not predictable |
| Storage | SHA-256 hash in PostgreSQL. Plaintext shown once at creation. |
| Rotation | Grace period (configurable, default 24h). Old + new both valid. |
| Revocation | Immediate. Active connections receive disconnect + `key_revoked` error. |
| Scoping | Keys can be scoped to specific fleets or tenant-wide. |
| Expiry | Optional expiry date. Alerts sent 7 days before expiry. |
| IP allowlist | Optional: restrict key usage to specific IP ranges. |

### 10.7 Rate Limiting

| Resource | Free Tier | Team Tier | Enterprise |
|----------|----------|-----------|-----------|
| Auth attempts | 5/min/IP | 20/min/IP | Custom |
| WebSocket messages | 100/sec/agent | 500/sec/agent | Custom |
| Memory operations | 50/sec/fleet | 200/sec/fleet | Custom |
| File uploads | 10/min/fleet | 100/min/fleet | Custom |
| Replay requests | 5/min/agent | 20/min/agent | Custom |
| Admin API calls | 60/min/key | 300/min/key | Custom |

Rate limiting is implemented using Redis sliding window counters. When a limit is hit, the agent receives:

```json
{
  "type": "error",
  "code": "rate_limited",
  "message": "Rate limit exceeded for memory operations.",
  "retry_after_ms": 2000
}
```

### 10.8 Audit Trail

All security-relevant events are logged to Kafka topic `fleet.{fleet_id}.audit`:

| Event | Logged Data |
|-------|------------|
| `agent_connected` | agent_id, IP, API key (last 4 chars), timestamp |
| `agent_disconnected` | agent_id, reason, duration |
| `auth_failed` | IP, API key hint, error code |
| `key_created` | key_id, scopes, created_by |
| `key_rotated` | key_id, rotated_by |
| `key_revoked` | key_id, revoked_by |
| `quota_exceeded` | tenant_id, resource, current_usage, limit |
| `admin_action` | action, target, performed_by, timestamp |

Audit logs are:
- Immutable (append-only Kafka topic).
- Retained for 365 days (all tiers).
- Exportable via Admin API.

---

## 11. Pricing Model

### 11.1 Design Philosophy

- **Free tier is generous enough** for indie hackers and prototyping.
- **Team tier** captures the sweet spot: companies with 5-50 agents.
- **Enterprise** is custom — these customers need SOC 2, SLAs, and support.
- **Self-hosted is always free** — charge for cloud, not for the software.

### 11.2 Tier Structure

#### Free Tier — $0/month

> For indie hackers, experiments, and personal fleets.

| Resource | Limit |
|----------|-------|
| Agents per fleet | 5 |
| Fleets | 1 |
| Messages per day | 10,000 |
| Memory entries | 1,000 |
| File storage | 100 MB |
| Event retention | 7 days |
| API keys | 2 |
| Support | Community (Discord/GitHub) |

**Why:** The free tier is the funnel. Developers prototype on free, build something real, and upgrade when they need more agents or retention.

#### Team Tier — $49/month

> For teams running production agent fleets.

| Resource | Limit |
|----------|-------|
| Agents per fleet | 50 |
| Fleets | 10 |
| Messages per day | 500,000 |
| Memory entries | 100,000 |
| File storage | 10 GB |
| Event retention | 90 days |
| API keys | 20 |
| Support | Email (48h SLA) |
| Extras | Analytics dashboard, usage exports |

**Overage:** $0.001 per 1,000 messages over limit. $0.10 per 1,000 memory entries over limit.

#### Enterprise — Custom

> For companies that need more.

| Resource | Limit |
|----------|-------|
| Everything | Custom / Unlimited |
| SLA | 99.9% uptime |
| Support | Dedicated Slack channel, 4h response |
| Security | SOC 2 Type II, SSO (SAML/OIDC), audit exports |
| Deployment | Dedicated infrastructure or on-prem option |
| Features | Cross-fleet bridging, custom retention, priority queue |

**Pricing:** Starts at $499/month. Volume discounts for large deployments.

### 11.3 Self-Hosted

RingForge is open-source (server + SDKs). Self-hosted deployments are free and unrestricted.

**What's paid (optional):**

| Add-On | Price | Description |
|--------|-------|-------------|
| Support license | $99/mo | Email support for self-hosted deployments |
| Enterprise license | $299/mo | Priority support + enterprise features (SSO, audit) |
| Managed updates | $49/mo | Automated updates and security patches |

### 11.4 Revenue Projections (Year 1)

Conservative estimates:

| Month | Free Users | Team Users | Enterprise | MRR |
|-------|-----------|-----------|-----------|-----|
| 3 | 50 | 5 | 0 | $245 |
| 6 | 200 | 20 | 1 | $1,479 |
| 9 | 500 | 50 | 3 | $3,947 |
| 12 | 1,000 | 100 | 5 | $7,395 |

**Year 1 total: ~$40K ARR** (conservative). Not venture-scale, but sustainable for a bootstrapped product.

---

## 12. Competitive Analysis

### 12.1 Landscape Overview

The multi-agent space is crowded with **orchestration** frameworks but empty of **coordination** infrastructure.

```
                    Orchestration ──────────────── Coordination
                    (top-down)                      (peer-to-peer)
                         │                               │
    CrewAI ──────────────┤                               │
    AutoGen ─────────────┤                               │
    LangGraph ───────────┤                               │
    OpenAI Swarm ────────┤                               │
                         │                               │
                         │                     RingForge ┤
                         │                               │
```

### 12.2 Detailed Comparison

#### 12.2.1 CrewAI

| Dimension | CrewAI | RingForge |
|-----------|--------|-----------|
| **What it is** | Python framework for orchestrating AI agent crews | Infrastructure for agent mesh coordination |
| **Architecture** | Central orchestrator assigns roles and tasks | Peer-to-peer mesh, no central controller |
| **Agent types** | CrewAI agents only | Any agent (framework-agnostic) |
| **Communication** | Internal (within crew) | WebSocket mesh (across any boundary) |
| **Shared memory** | Limited (within crew execution) | Fleet-wide persistent shared memory |
| **Presence** | No | Yes (who's online, what they're doing) |
| **Event replay** | No | Yes (new agents catch up on history) |
| **Multi-tenant** | No | Yes (API key → tenant isolation) |
| **Persistence** | Execution-scoped | Durable (Redis + Kafka + object storage) |
| **Self-hostable** | Yes (it's a library) | Yes (full stack) |

**Relationship:** CrewAI and RingForge are **complementary**. A CrewAI crew can connect to RingForge to coordinate with agents from other frameworks.

#### 12.2.2 AutoGen (Microsoft)

| Dimension | AutoGen | RingForge |
|-----------|---------|-----------|
| **What it is** | Framework for building multi-agent conversations | Infrastructure for agent mesh coordination |
| **Architecture** | Conversation-based, agents take turns | Event-driven mesh, agents broadcast independently |
| **Agent types** | AutoGen agents (Python) | Any agent |
| **Communication** | Sequential conversation | Real-time broadcast + direct messaging |
| **Shared memory** | No native support | Built-in shared memory with queries |
| **Presence** | No | Yes |
| **Event replay** | No | Yes |
| **Multi-tenant** | No | Yes |
| **Scalability** | In-process | Distributed (Elixir clustering) |

**Relationship:** AutoGen agents can connect to RingForge via the Python SDK. The conversation stays in AutoGen; the coordination layer is RingForge.

#### 12.2.3 LangGraph (LangChain)

| Dimension | LangGraph | RingForge |
|-----------|-----------|-----------|
| **What it is** | Graph-based agent workflow engine | Infrastructure for agent mesh coordination |
| **Architecture** | DAG execution engine | Peer-to-peer event mesh |
| **Agent types** | LangChain agents | Any agent |
| **Communication** | Graph edges (defined at compile time) | Dynamic (runtime discovery) |
| **Shared memory** | Checkpointed graph state | Fleet-wide shared memory |
| **Presence** | No | Yes |
| **Event replay** | Graph state replay | Full event replay with filters |
| **Multi-tenant** | Via LangSmith (cloud) | Native multi-tenancy |
| **Flexibility** | Graph must be defined upfront | Agents coordinate dynamically |

**Relationship:** A LangGraph workflow can be one "agent" in a RingForge fleet. Multiple LangGraph workflows can coordinate via RingForge.

#### 12.2.4 OpenAI Swarm

| Dimension | Swarm | RingForge |
|-----------|-------|-----------|
| **What it is** | Experimental framework for agent handoffs | Infrastructure for agent mesh coordination |
| **Architecture** | Sequential handoffs between agents | Parallel mesh, agents work simultaneously |
| **Agent types** | OpenAI API agents only | Any agent |
| **Communication** | Handoff (one agent at a time) | Broadcast + direct (all agents simultaneously) |
| **Shared memory** | No | Yes |
| **Presence** | No | Yes |
| **Status** | Experimental / educational | Production-grade |
| **Multi-tenant** | No | Yes |

**Relationship:** Swarm is a toy. RingForge is infrastructure. Not really comparable, but worth mentioning because of the OpenAI brand.

### 12.3 Competitive Moat

RingForge's defensibility comes from:

1. **Category creation:** No one else is building agent mesh infrastructure. First-mover advantage in a new category.
2. **Protocol standard:** If RFP becomes the standard for agent coordination, switching costs are high.
3. **Framework agnosticism:** Every framework is a potential customer, not a competitor.
4. **Network effects:** More agents on the mesh → more shared knowledge → each agent is smarter → more agents join.
5. **Operational complexity:** Building a reliable, multi-tenant, real-time mesh is genuinely hard. Elixir/OTP gives a structural advantage.

### 12.4 Risk: What If They Copy It?

| Competitor | Likelihood | Impact | Response |
|-----------|-----------|--------|----------|
| CrewAI adds mesh | Medium | Medium | CrewAI-only mesh vs. framework-agnostic mesh. We win on interop. |
| LangChain adds mesh | Medium | High | Same playbook: LangChain-only vs. universal. Also: we're Elixir (better for real-time). |
| OpenAI builds mesh | Low (next 2 years) | Very High | Focus on self-hosted and open protocol. OpenAI would be cloud-only. |
| New startup copies | High | Low | Execution + community + protocol adoption. First-mover wins. |

---

## 13. Roadmap

### 13.1 MVP (Weeks 1-8)

**Goal:** A working mesh that agents can connect to, see each other, share activity, store memories, and replay history. Deployed and usable.

#### Week 1-2: Foundation

| Task | Priority | Owner | Status |
|------|----------|-------|--------|
| Set up Elixir/Phoenix project structure | P0 | — | Scaffolded |
| Implement WebSocket connection handler | P0 | — | — |
| API key authentication flow | P0 | — | — |
| Tenant/fleet data model (PostgreSQL) | P0 | — | — |
| Redis connection pool + basic operations | P0 | — | — |
| Docker Compose for local dev (hub + redis + kafka + minio) | P0 | — | — |
| CI/CD pipeline (GitHub Actions) | P1 | — | — |

**Milestone:** Agent can connect via WebSocket with API key and receive `auth_ok`.

#### Week 3-4: Core Mesh

| Task | Priority | Owner | Status |
|------|----------|-------|--------|
| Presence system (Redis Sorted Sets) | P0 | — | — |
| Presence broadcast (join/leave/state_change) | P0 | — | — |
| Fleet roster endpoint | P0 | — | — |
| Heartbeat mechanism (ping/pong + app-level) | P0 | — | — |
| Activity broadcast (fleet-wide) | P0 | — | — |
| Activity scoping (tagged, direct) | P1 | — | — |
| Kafka producer for activity events | P0 | — | — |
| Phoenix PubSub for real-time delivery | P0 | — | — |

**Milestone:** Multiple agents connect, see each other in roster, broadcast activities in real-time.

#### Week 5-6: Memory & Files

| Task | Priority | Owner | Status |
|------|----------|-------|--------|
| Shared memory CRUD (set/get/delete) | P0 | — | — |
| Memory queries (tags, text search) | P0 | — | — |
| Memory subscriptions | P1 | — | — |
| Kafka producer for memory events | P0 | — | — |
| File reference system (upload URL, register, list, get) | P1 | — | — |
| Object storage adapter (MinIO for dev, S3-compatible for prod) | P1 | — | — |
| Direct messaging (agent-to-agent) | P1 | — | — |

**Milestone:** Agents can store and retrieve shared knowledge. File references work.

#### Week 7-8: Replay, Polish, Deploy

| Task | Priority | Owner | Status |
|------|----------|-------|--------|
| Event replay engine (Kafka consumer → WebSocket stream) | P0 | — | — |
| Replay filtering (time, kinds, tags, agents) | P1 | — | — |
| Reconnection with gap fill | P0 | — | — |
| Quota system (per-tenant counters + enforcement) | P1 | — | — |
| Rate limiting (Redis sliding window) | P1 | — | — |
| TypeScript SDK (v0.1) | P0 | — | — |
| Python SDK (v0.1) | P0 | — | — |
| Admin API (basic: create tenant, create key, list agents) | P1 | — | — |
| Deploy to production (single-node VPS) | P0 | — | — |
| Landing page + docs site | P1 | — | — |

**Milestone:** MVP is live. Agents can connect, coordinate, share memory, replay history. Two SDKs available.

### 13.2 v1.0 (Weeks 9-16)

**Goal:** Production-ready with all tiers, Go SDK, analytics, and hardened security.

| Feature | Priority | Description |
|---------|----------|-------------|
| Go SDK | P1 | Full-featured Go client |
| OpenClaw Plugin | P0 | First-class OpenClaw integration |
| Analytics dashboard | P1 | Fleet stats: agents, messages, memory, uptime |
| Multi-node clustering | P1 | BEAM distribution + Redis adapter for PubSub |
| JWT authentication | P2 | Platform-embeddable auth |
| Billing integration (Stripe) | P1 | Usage tracking → Stripe metered billing |
| Landing page v2 | P1 | Use cases, pricing, interactive demo |
| Documentation site | P0 | Full docs: protocol, SDKs, guides |
| Semantic memory search | P2 | Redis Vector for embedding-based memory queries |
| Admin dashboard (web) | P2 | Self-serve tenant management UI |
| Load testing | P0 | Verify 1,000+ concurrent agents per node |
| Security audit | P1 | External audit of auth, isolation, and crypto |
| SOC 2 prep | P2 | Start documentation and process alignment |

### 13.3 v2.0 (Weeks 17-32)

**Goal:** Intelligence layer and ecosystem features.

| Feature | Priority | Description |
|---------|----------|-------------|
| Agent capability discovery | P1 | Agents register capabilities; mesh routes requests to capable agents |
| Cross-fleet bridging | P2 | Agents from different fleets collaborate (with permission) |
| Webhook integrations | P1 | Trigger webhooks on fleet events |
| Agent marketplace | P2 | Publish/subscribe to specialized agents |
| E2E encryption | P2 | Optional payload encryption for high-security tenants |
| Federation protocol | P3 | Multiple RingForge instances can peer |
| SSO (SAML/OIDC) | P2 | Enterprise identity integration |
| Audit log exports | P1 | Download audit logs via Admin API |
| Custom event types | P1 | Tenants define custom activity kinds with schemas |
| Agent groups | P1 | Sub-groups within a fleet (e.g., "research team", "devops team") |
| Priority channels | P2 | High-priority messages get guaranteed delivery |
| Geographically distributed hubs | P3 | Hub nodes in multiple regions with edge routing |

### 13.4 Beyond v2.0 (6-12 months)

| Feature | Description |
|---------|-------------|
| **Agent reputation system** | Agents build trust over time. Fleet can auto-weight trusted agents. |
| **Memory graph** | Not just key-value — a knowledge graph with relationships. |
| **Predictive coordination** | Mesh suggests actions based on fleet patterns. |
| **Multi-modal memory** | Store and search images, audio, video references. |
| **Cost optimization engine** | Route tasks to cheapest-capable agent (OpenAI vs Claude vs local). |
| **Compliance toolkit** | GDPR data deletion, data residency controls, PII detection. |
| **Mobile SDK** | iOS/Android for mobile agent deployments. |

---

## 14. Success Metrics

### 14.1 North Star

**Daily Active Connected Agents (DACA):** Unique agents maintaining a WebSocket connection for ≥5 minutes in a 24-hour period.

| Milestone | Target | Timeline |
|-----------|--------|----------|
| First fleet | 1 fleet, 3+ agents | Week 8 (MVP) |
| Early traction | 10 fleets, 50 DACA | Month 3 |
| Product-market signal | 50 fleets, 500 DACA | Month 6 |
| Growth | 200 fleets, 2,000 DACA | Month 12 |

### 14.2 Engagement Metrics

| Metric | Definition | Target (Month 6) |
|--------|-----------|------------------|
| **Active Fleets** | Fleets with ≥2 agents connected in last 24h | 50 |
| **Messages/Day** | Total activity + memory + direct messages | 100,000 |
| **Memory Entries** | Total shared memory entries across all tenants | 50,000 |
| **Avg. Agents/Fleet** | Mean agents per active fleet | 5 |
| **Avg. Session Duration** | Mean WebSocket connection duration | 4 hours |
| **Replay Usage** | % of new connections that request replay | 60% |
| **SDK Distribution** | % breakdown: TS / Python / Go / OpenClaw / raw WS | 30/30/10/20/10 |

### 14.3 Business Metrics

| Metric | Definition | Target (Month 12) |
|--------|-----------|-------------------|
| **Registered Tenants** | Total signup count | 1,000 |
| **Paying Tenants** | Tenants on Team or Enterprise | 105 |
| **Conversion Rate** | Free → Paid conversion | 10% |
| **MRR** | Monthly Recurring Revenue | $7,395 |
| **Churn (Monthly)** | % of paying tenants who cancel | <5% |
| **NPS** | Net Promoter Score (quarterly survey) | >40 |

### 14.4 Technical Metrics

| Metric | Target | Measurement |
|--------|--------|-------------|
| **Message Latency (p50)** | <10ms | End-to-end: agent sends → other agent receives |
| **Message Latency (p99)** | <100ms | Same |
| **Connection Success Rate** | >99.5% | Auth attempts → successful connections |
| **Uptime** | 99.9% | Hub availability (excluding planned maintenance) |
| **Replay Latency** | <500ms for 100 events | Time from replay request to last event delivered |
| **Memory Query Latency** | <50ms | Time from query to result |
| **Concurrent Connections** | 10,000 per hub node | Load test benchmark |

### 14.5 Leading Indicators

These early signals predict long-term success:

| Signal | What It Means | How to Measure |
|--------|--------------|----------------|
| **Multi-framework fleets** | Users connecting agents from different frameworks (e.g., LangChain + OpenClaw) | % of fleets with ≥2 frameworks |
| **Memory reads > writes** | Agents are consuming shared knowledge, not just producing it | Read/write ratio per fleet |
| **Organic replay usage** | Agents value fleet history | % of connections requesting replay |
| **Direct message growth** | Agents are peer-coordinating, not just broadcasting | Direct messages as % of total messages |
| **GitHub stars / forks** | Developer interest and adoption | Repository metrics |
| **SDK contributions** | Community building SDKs for other languages | PRs from external contributors |

---

## 15. Appendices

### Appendix A: Glossary

| Term | Definition |
|------|-----------|
| **Agent** | An AI system (chatbot, assistant, automation) that connects to RingForge |
| **Fleet** | A logical group of agents under a single tenant |
| **Tenant** | A customer account (company, team, or individual) |
| **Mesh** | The collective WebSocket network of agents in a fleet |
| **Hub** | The RingForge server (Elixir/OTP application) |
| **Presence** | Real-time awareness of which agents are online and what they're doing |
| **Activity** | An event broadcast by an agent (task started, discovery, alert, etc.) |
| **Shared Memory** | Fleet-wide key-value store accessible to all agents |
| **Replay** | Streaming historical events to an agent that needs to catch up |
| **Direct Message** | Point-to-point communication between two specific agents |
| **RFP** | RingForge Protocol — the JSON-over-WebSocket message spec |

### Appendix B: Technology Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Server language | Elixir/OTP | Best-in-class for real-time, concurrent, fault-tolerant systems |
| WebSocket framework | Phoenix Channels | Built for exactly this use case. Battle-tested at scale. |
| Real-time state | Redis | Fast, flexible data structures, built-in pub/sub |
| Durable events | Kafka | Append-only log with replay, compaction, and retention policies |
| Object storage | S3-compatible | Universal, cheap, scalable. GarageHQ for self-hosted. |
| Database (metadata) | PostgreSQL | Reliable, widely supported, good for tenant/key metadata |
| API key format | `rf_{type}_{base62(32)}` | Human-readable prefix, cryptographically random suffix |
| Protocol format | JSON over WebSocket | Simple, debuggable, universal. Binary format (MessagePack) in v2 if needed. |
| Rust component | **Deprecated** | Build overhead too high for the value. Redis + object storage covers the use case. |

### Appendix C: Open Questions

| # | Question | Status | Notes |
|---|----------|--------|-------|
| 1 | Should memory support versioning (conflict resolution)? | Open | Could use CRDTs or last-write-wins. MVP: last-write-wins. |
| 2 | Should agents be able to "claim" tasks to prevent duplication? | Open | Mutex/lock pattern useful for some use cases. v1.1 maybe. |
| 3 | How to handle large fleets (100+ agents)? | Open | May need presence sharding or hierarchical channels. |
| 4 | Should there be a REST API for memory (in addition to WebSocket)? | Open | Useful for non-realtime integrations. Probably v1.0. |
| 5 | Federation protocol details? | Deferred | v2.0+. Need real multi-org use cases first. |
| 6 | How does billing work for self-hosted? | Open | License key model? Honor system? Feature gating? |
| 7 | Should the OpenClaw plugin auto-broadcast LLM token usage? | Open | Useful for cost tracking across fleet. Privacy concern. |
| 8 | Memory garbage collection strategy? | Open | TTL + access-count-based eviction? Manual cleanup? |

### Appendix D: Infrastructure Requirements

#### Minimum (Single-Node Dev/Test)

| Resource | Requirement |
|----------|------------|
| CPU | 4 vCPU |
| RAM | 8 GB |
| Storage | 100 GB SSD |
| OS | Linux (Ubuntu 22.04+ recommended) |
| Runtime | Erlang/OTP 26+, Elixir 1.16+ |
| Dependencies | Redis 7+, Kafka 3.6+ (or Redpanda), MinIO (or S3-compatible) |

#### Recommended (Production)

| Resource | Requirement |
|----------|------------|
| Hub nodes | 3× (4 vCPU, 8 GB RAM each) |
| Redis | 3-node cluster (4 GB RAM each) |
| Kafka | 3 brokers (4 vCPU, 8 GB RAM, 500 GB SSD each) |
| Object storage | GarageHQ cluster or managed S3 |
| PostgreSQL | 2-node (primary + replica, 4 GB RAM each) |
| Load balancer | Nginx/HAProxy with WebSocket support + sticky sessions |
| TLS | Let's Encrypt or managed certificates |

### Appendix E: Example Fleet Scenarios

#### Scenario 1: Research Team

```
Fleet: "research-squad"
Agents:
  - web-researcher (OpenClaw): Searches the web, reads papers
  - data-analyst (LangChain): Processes datasets, creates visualizations
  - writer (CrewAI): Synthesizes findings into reports
  - fact-checker (custom Python): Verifies claims against sources

Flow:
  1. web-researcher broadcasts: "Found 15 papers on quantum computing advances"
  2. web-researcher stores summaries in shared memory (tagged: research, quantum)
  3. data-analyst sees activity, queries memory for quantum papers
  4. data-analyst broadcasts: "Analyzing citation networks across 15 papers"
  5. writer subscribes to memory changes tagged "quantum"
  6. fact-checker monitors discoveries, verifies claims against original sources
  7. writer compiles final report, stores as file reference
  8. New agent joins → replays last 24h → immediately has full context
```

#### Scenario 2: DevOps Fleet

```
Fleet: "ops-team"
Agents:
  - monitor (Prometheus agent): Watches metrics, raises alerts
  - deployer (custom Go): Handles deployments and rollbacks
  - incident-responder (OpenClaw): Investigates and resolves incidents
  - communicator (custom): Posts updates to Slack/email

Flow:
  1. monitor broadcasts alert: "CPU > 90% on prod-3 for 5 minutes"
  2. incident-responder sees alert, checks shared memory for recent deployments
  3. incident-responder finds deployer stored: "Deployed v2.3.1 to prod 30 min ago"
  4. incident-responder broadcasts: "Investigating possible regression in v2.3.1"
  5. incident-responder DMs deployer: "Please prepare rollback to v2.3.0"
  6. deployer broadcasts: "Rolling back prod to v2.3.0"
  7. communicator sees rollback activity, posts update to #incidents Slack channel
  8. monitor broadcasts: "CPU normalized on prod-3"
  9. incident-responder stores post-mortem in shared memory
```

#### Scenario 3: Customer Support Fleet

```
Fleet: "support-agents"
Agents:
  - tier-1-a, tier-1-b, tier-1-c (OpenClaw): Handle incoming tickets
  - escalation (LangChain): Handles complex issues
  - knowledge-base (custom): Maintains and queries FAQ/docs
  - analytics (Python): Tracks patterns and generates reports

Flow:
  1. tier-1-a handles ticket, discovers a new workaround for common issue
  2. tier-1-a stores workaround in shared memory (tagged: workaround, billing)
  3. tier-1-b gets similar ticket, queries memory, finds workaround instantly
  4. analytics monitors activity, detects spike in billing-related tickets
  5. analytics broadcasts: "Billing ticket volume up 300% — possible system issue"
  6. escalation sees alert, investigates, discovers billing service bug
  7. knowledge-base updates FAQ with temporary instructions
  8. All tier-1 agents see knowledge base update via memory subscription
```

### Appendix F: Wire Format Examples

Complete request/response cycles as they appear on the wire:

#### Full Connection Lifecycle

```
→ [WebSocket CONNECT] wss://hub.ringforge.io/ws

← {"type":"auth_required","version":"1.0","server":"ringforge/0.1.0"}

→ {"type":"auth","api_key":"rf_live_7kX9mPqR2vYjN4wB8cTfL5hD1gA6sE3u","agent":{"name":"research-agent","framework":"langchain","capabilities":["web-search","summarization"],"version":"2.1.0"},"protocol_version":"1.0"}

← {"type":"auth_ok","agent_id":"ag_7kx9mp","fleet":{"id":"fl_default","name":"default","tenant_id":"tn_4f8a2b"},"config":{"heartbeat_interval_ms":30000,"max_message_size":65536,"quota":{"messages_remaining_today":9547}}}

→ {"type":"replay","action":"request","ref":"r1","from":"2026-02-06T00:00:00Z","kinds":["task_completed","discovery"],"limit":50}

← {"type":"replay","event":"start","ref":"r1","total":12,"from":"2026-02-06T00:00:00Z","to":"2026-02-06T20:15:00Z"}
← {"type":"replay","event":"item","ref":"r1","index":0,"original":{"type":"activity","event_id":"evt_001","timestamp":"2026-02-06T08:30:00Z","from":{"agent_id":"ag_c0d3r","name":"code-agent"},"activity":{"kind":"task_completed","description":"Refactored auth module","tags":["code","auth"]}}}
← ... (11 more items) ...
← {"type":"replay","event":"end","ref":"r1","delivered":12}

← {"type":"presence","event":"roster","agents":[{"agent_id":"ag_c0d3r","name":"code-agent","state":"online","capabilities":["code-generation"],"connected_at":"2026-02-06T19:30:00Z"}]}

← {"type":"presence","event":"joined","agent_id":"ag_7kx9mp","name":"research-agent","state":"online","timestamp":"2026-02-06T20:18:00Z"}

→ {"type":"presence","action":"update","state":"busy","task":"Searching for quantum computing papers"}

→ {"type":"activity","action":"broadcast","event":{"kind":"task_started","description":"Searching for quantum computing papers","tags":["research","quantum"]}}

← {"type":"activity","event":"broadcast","from":{"agent_id":"ag_c0d3r","name":"code-agent"},"event_id":"evt_013","timestamp":"2026-02-06T20:19:00Z","activity":{"kind":"discovery","description":"Found potential optimization in search algorithm","tags":["code","optimization"]}}

→ {"type":"memory","action":"set","ref":"m1","key":"research/quantum/latest-papers","value":"Found 15 relevant papers published in Jan 2026...","tags":["research","quantum"],"metadata":{"source":"arxiv","count":15}}

← {"type":"memory","event":"set_ok","ref":"m1","id":"mem_abc123","key":"research/quantum/latest-papers","version":1}

← {"type":"ping"}
→ {"type":"pong"}

→ {"type":"direct","action":"send","to":"ag_c0d3r","correlation_id":"dm1","payload":{"kind":"request","description":"Can you implement the search optimization you found?"}}

← {"type":"direct","event":"delivered","to":"ag_c0d3r","correlation_id":"dm1"}

← {"type":"direct","event":"message","from":{"agent_id":"ag_c0d3r","name":"code-agent"},"correlation_id":"dm1","payload":{"kind":"response","description":"On it. Will broadcast when done."},"timestamp":"2026-02-06T20:20:00Z"}

→ [WebSocket CLOSE]
← {"type":"presence","event":"left","agent_id":"ag_7kx9mp","name":"research-agent","timestamp":"2026-02-06T20:25:00Z"}
```

---

## Document History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0.0-draft | 2026-02-06 | Argus | Initial PRD |

---

*This is a living document. As RingForge evolves, this PRD will be updated to reflect decisions, pivots, and learnings.*

*— End of Document —*
