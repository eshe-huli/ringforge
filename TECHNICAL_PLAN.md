# RingForge — Technical Plan

> **Created:** 2026-02-07
> **Updated:** 2026-02-07 (v2 — new direction)
> **Author:** Ben Ouattara + Onyx Key
> **Principle:** Build for 10, design for 10,000, plan for 1,000,000
> **Scope:** Dev roadmap, orchestration architecture, auto-scaling infrastructure, security posture

---

## Table of Contents

1. [Current State](#1-current-state)
2. [Development Plan](#2-development-plan)
3. [Orchestration Architecture](#3-orchestration-architecture)
4. [Infrastructure — Auto-Scaling Path](#4-infrastructure--auto-scaling-path)
5. [Security Architecture](#5-security-architecture)
6. [Data Architecture](#6-data-architecture)
7. [Observability](#7-observability)
8. [Migration Playbook](#8-migration-playbook)

---

## 1. Current State

### What's Built (Phases 1-8) — All Running on VPS30

```
┌─────────────────────────────────────────────────┐
│  VPS30 (38.242.159.237) — Contabo 8C/32GB       │
│                                                   │
│  Ringforge Hub (Elixir/OTP)                      │
│  ├── Phoenix Channels (WebSocket transport)      │
│  ├── FleetPresence (Phoenix.Presence)            │
│  ├── TaskSupervisor (GenServer, 1s tick)          │
│  ├── TaskRouter (capability matching)             │
│  ├── OllamaBridge (2 virtual agents)             │
│  ├── LiveView Dashboard (6 pages + wizard)       │
│  ├── Admin REST API + Quotas                     │
│  └── Groups/Squads/Pods                          │
│                                                   │
│  Postgres │ Redis │ Kafka │ Ollama │ MinIO │ Traefik│
│  Capacity: ~500 agents, ~50 fleets               │
└─────────────────────────────────────────────────┘
```

### What's Production-Ready ✅

| Layer | What | Status |
|-------|------|--------|
| Auth | Tenant, Fleet, ApiKey, Agent (Ecto) + Ed25519 (partial) | ✅ |
| Transport | Phoenix Channels + custom JSON envelope + idempotency (ETS) | ✅ |
| Presence | Phoenix.Presence (FleetPresence) | ✅ |
| Activity | Broadcast + EventBus behaviour (local impl) | ✅ |
| Memory | CRUD + query + subscriptions | ✅ |
| Messaging | DMs + offline queue + delivery | ✅ |
| Replay | Event replay by time/kind/tag/agent | ✅ |
| Groups | Squads, pods, channels | ✅ |
| Tasks | Submit, route (capability+load), claim, result | ✅ |
| Workers | OllamaBridge (qwen2.5-coder:7b, llama3.1:8b) | ✅ |
| Admin | REST API + quota enforcement | ✅ |
| Dashboard | LiveView, 6 pages, Add Agent wizard, SaladUI | ✅ |
| Security | SSH hardened, Fail2ban, UFW, bcrypt, SHA-256 keys, CSRF, HSTS | ✅ |

### What's NOT Production-Ready ❌

| Gap | Risk | Target Fix |
|-----|------|------------|
| Single node | Total failure = total outage | Tier 1 clustering |
| ETS tasks | Lost on restart | Redis-backed tasks |
| Local EventBus | No durability, no replay across restarts | Kafka production |
| No per-agent rate limiting | DoS from single agent | Phase 9 |
| No TLS between internal services | MITM in multi-node | mTLS at Tier 1 |
| Ollama on same box | Competes for Hub RAM | Separate GPU node |
| No automated backups | Data loss risk | Pre-Tier 1 |
| No auto-scaling | Manual intervention | Tier 1+ provider |

---

## 2. Development Plan

### Phase 9 — SDK Publishing & Polish (Week 1-2)

**Goal:** `npm install @ringforge/sdk` and `pip install ringforge` work.

**TypeScript SDK (`@ringforge/sdk`):**

```
src/
├── client.ts          # WebSocket connection, auth, reconnect (exp backoff)
├── presence.ts        # Roster, update, subscribe
├── activity.ts        # Broadcast, subscribe, history
├── memory.ts          # CRUD, query, subscribe
├── messaging.ts       # DMs, history
├── tasks.ts           # Submit, status, results
├── groups.ts          # Create, join, message
└── types.ts           # Full TypeScript types
```

Key features:
- Auto-reconnect with exponential backoff
- Event-driven (callbacks + async iterators)
- Built-in idempotency
- Fleet:lobby auto-resolve (no fleet_id needed)
- Type-safe generics

**Python SDK (`ringforge`):**

```
ringforge/
├── client.py          # websockets + asyncio, auth, reconnect
├── presence.py        # Same API surface as TypeScript
├── activity.py
├── memory.py
├── messaging.py
├── tasks.py
├── groups.py
└── types.py           # dataclasses + type hints
```

**Deliverables:**
- [ ] `@ringforge/sdk` on npm (CI publish pipeline)
- [ ] `ringforge` on PyPI (CI publish pipeline)
- [ ] Integration tests against live hub
- [ ] README + quickstart for both

**Exit criteria:** 3 frameworks can connect (OpenClaw, raw Python, raw Node.js).

---

### Phase 10 — OpenClaw RingForge Plugin (Week 2-3)

**Architecture:**

```
OpenClaw Agent
├── openclaw.yaml
│   └── ringforge:
│       enabled: true
│       server: "wss://hub.ringforge.io"
│       apiKey: "rf_live_xxx"
│       agentName: "my-agent"
│       capabilities: ["code", "research"]
│       injection: "immediate"
│
└── Plugin: ringforge-plugin.js
    ├── onConnect()      → Join fleet, set presence "online"
    ├── onDisconnect()   → Clean up
    ├── onDM()           → Inject as system event → agent turn
    ├── onTaskAssigned() → Inject as system event → agent executes
    ├── onHeartbeat()    → Update presence state + current task
    └── Tools exposed:
        ├── ringforge_send(agent_id, message)
        ├── ringforge_roster()
        ├── ringforge_memory(action, key, value)
        ├── ringforge_task_submit(type, prompt, capabilities)
        └── ringforge_activity(kind, description)
```

**DM → Agent Turn injection modes:**

| Mode | Behavior | Trigger |
|------|----------|---------|
| `immediate` | System event → agent turn now | `priority: "high"` |
| `queue` | Inbox, checked on next heartbeat | Default |
| `interrupt` | Mid-turn injection with priority flag | `priority: "critical"` |

---

### Phase 11 — File Distribution (Week 3-4)

```
Agent → Hub: file.upload_url(filename, size, content_type)
Hub → Agent: {presigned_put_url, file_id, expires: 3600}
Agent → S3:  HTTP PUT (direct upload, no hub bottleneck)
Agent → Hub: file.register(file_id, tags, description)
Hub → Fleet: broadcast file registered
```

Backend: Garage (self-host) → S3/R2 (cloud). Adapter pattern.

---

### Phase 12 — Kafka Production EventBus (Week 4-5)

Switch from `Hub.EventBus.Local` (ETS, volatile) to `Hub.EventBus.Kafka` (durable, replayable, multi-node).

**Topics:**

| Topic | Partitions | Retention | Purpose |
|-------|-----------|-----------|---------|
| `rf.{fleet}.activity` | 6 | Per plan (24h-90d) | Activity events |
| `rf.{fleet}.memory` | 3 | Compacted | Memory changelog |
| `rf.{fleet}.tasks` | 6 | 7d | Task lifecycle |
| `rf.{fleet}.audit` | 1 | 365d | Security audit |
| `rf.system.telemetry` | 3 | 7d | Platform metrics |

Partitioning: activity by `agent_id`, memory by `key`, audit single-partition for strict ordering.

---

### Phase 13 — Ed25519 Full Auth Flow (Week 5-6)

```
FIRST CONNECT:
  Agent generates Ed25519 keypair → stores private key locally
  Agent → Hub: {api_key: "rf_live_...", agent: {public_key: "<base64>"}}
  Hub: Binds pubkey to agent record in DB

RECONNECT (zero credentials on wire):
  Agent → Hub: {agent_id: "ag_xxx"}
  Hub → Agent: {challenge: "<32 random bytes>"}
  Agent: signs challenge with private key
  Agent → Hub: {signature: "<base64>"}
  Hub: verify(agent.public_key, challenge, signature)
  Hub → Agent: {auth_ok}
```

SDK handles all crypto automatically. Developer never sees it.

---

### Phase 14 — Stripe Billing (Week 6-8)

**Plans:**

| | Free | Pro ($29/mo) | Scale ($99/mo) | Enterprise |
|---|---|---|---|---|
| Agents | 10 | 100 | 1,000 | Unlimited |
| Messages/day | 50K | 500K | 5M | Unlimited |
| Memory entries | 5K | 100K | 1M | Unlimited |
| Fleets | 1 | 5 | 25 | Unlimited |
| File storage | 1 GB | 25 GB | 250 GB | Custom |
| Retention | 24h | 7d | 30d | 90d+ |
| Webhooks | ❌ | ✅ | ✅ | ✅ |
| Audit logs | ❌ | ❌ | ✅ | ✅ |

**Flow:**
```
Registration → Stripe Customer → Free plan (no card)
  → Dashboard "Upgrade" → Stripe Checkout (hosted)
    → Webhook: invoice.paid → Update tenant.plan → Quotas adjusted
```

Soft limit at 80% (warning). Hard limit at 100% (reject + upgrade CTA).

---

### Phase 15 — Social Login & Invite System (Week 8-9)

- GitHub OAuth2 (primary — target audience is devs)
- Google OAuth2
- Magic link email
- Invite code system (admin-generated, limited uses)
- Optional TOTP 2FA

---

### Phase 16 — Webhooks & Callbacks (Week 9-10)

- HMAC-SHA256 signed payloads
- Retry with exponential backoff (3 attempts)
- Events: agent.connected/disconnected, message.received, activity.broadcast, memory.changed, task.completed
- Dashboard webhook management + delivery logs

---

### Phase 17 — Agent Provisioning from Dashboard (Week 10-12)

- Cloud provider integrations: Hetzner, DigitalOcean, Contabo, AWS
- Template selection (OpenClaw, custom, bare)
- One-click: spin VPS → install agent → connect to fleet
- Cost tracking per agent
- Provider credentials management (encrypted, per-tenant)

---

## 3. Orchestration Architecture

### 3.1 Current: Simple Routing (Phase 8)

```
Agent A → task:submit → Hub → TaskRouter.route() → Agent B (best match)
                                 │
                                 ├── Filter: capabilities match
                                 ├── Filter: agent state (online/busy)
                                 └── Select: lowest load
```

Works. But limited:
- No task persistence (ETS = lost on restart)
- No chaining (A → B → C)
- No retry on worker failure
- No priority queues
- No cost-aware routing

### 3.2 Target: Advanced Orchestration

#### 3.2.1 Task Persistence (Redis)

Move from ETS to Redis for cross-node task state:

```
rf:task:{task_id}           → Hash (status, requester, assigned_to, prompt, type, result, created_at, ttl)
rf:tasks:pending:{fleet_id} → Sorted Set (score = priority * 1000 + timestamp) — priority queue
rf:tasks:agent:{agent_id}   → Set (tasks assigned to agent — cleanup on disconnect)
```

TTL auto-cleanup. No stale tasks.

#### 3.2.2 Task Chains (Pipelines)

Sequential task execution, output feeds into next step:

```json
{
  "type": "task",
  "action": "pipeline",
  "payload": {
    "name": "Research & Summarize",
    "steps": [
      {"type": "general", "prompt": "Search for recent AI news", "capabilities": ["research"]},
      {"type": "general", "prompt": "Summarize: {{prev.result}}", "capabilities": ["summarize"]},
      {"type": "code", "prompt": "Format as markdown: {{prev.result}}", "capabilities": ["code"]}
    ]
  }
}
```

Hub executes sequentially. `{{prev.result}}` is template-substituted. Each step routed independently.

#### 3.2.3 Fan-Out / Fan-In (Parallel Tasks)

```json
{
  "type": "task",
  "action": "parallel",
  "payload": {
    "tasks": [
      {"type": "code", "prompt": "Lint this file", "capabilities": ["code"]},
      {"type": "code", "prompt": "Run tests", "capabilities": ["code"]},
      {"type": "general", "prompt": "Security review", "capabilities": ["security"]}
    ],
    "merge": "collect"  // or "first_success" or "majority_vote"
  }
}
```

#### 3.2.4 Smart Routing — Weighted Scoring

Phase 8: capability match + load balancing.
Next: multi-signal weighted scoring.

| Signal | Weight | Description |
|--------|--------|-------------|
| Capability match | Required | Must have ALL required capabilities |
| Agent state | 0.30 | online > busy (load < 0.8) > never away/offline |
| Load | 0.25 | Prefer lower-load agents |
| Latency history | 0.20 | Faster agents for similar past tasks |
| Success rate | 0.15 | Higher completion rate preferred |
| Cost | 0.10 | Local LLMs (free) vs cloud LLMs (paid) |

```elixir
defmodule Hub.TaskRouter do
  def route(task, fleet_id) do
    fleet_id
    |> get_online_agents()
    |> filter_by_capabilities(task.capabilities_required)
    |> filter_by_state()
    |> score_agents(task)
    |> select_best()
  end

  defp score_agents(agents, task) do
    Enum.map(agents, fn agent ->
      score =
        state_score(agent) * 0.3 +
        load_score(agent) * 0.25 +
        latency_score(agent, task.type) * 0.2 +
        success_score(agent, task.type) * 0.15 +
        cost_score(agent) * 0.1
      {agent, score}
    end)
    |> Enum.sort_by(&elem(&1, 1), :desc)
  end
end
```

**Cost-aware routing:** Non-priority tasks → local LLMs (free). Priority/complex → cloud LLMs (paid). Saves money at scale.

#### 3.2.5 Worker Types

| Worker Type | Examples | Characteristics |
|-------------|----------|-----------------|
| Local LLM | Ollama qwen, llama, mistral | Free, fast, simple tasks |
| Cloud LLM | Claude, GPT (via OpenClaw) | Expensive, smart, complex reasoning |
| Specialized | Code formatter, linter, test runner | Deterministic, fast |
| Human-in-loop | Dashboard operator approval | Slow, high-stakes decisions |
| External API | Web search, data fetch | I/O bound, rate limited |

All treated as fleet peers. The Hub doesn't care what's behind the agent.

#### 3.2.6 Task Observability

Lifecycle events in the activity stream:

```
task_submitted → task_routed → task_assigned → task_claimed → task_running → task_completed
                                                                            └→ task_failed
                                                                            └→ task_timeout → task_reassigned
```

Dashboard shows: active tasks, completion rates per agent, avg routing time, avg execution time, failed task analysis.

---

## 4. Infrastructure — Auto-Scaling Path

> **Note:** VPS30 is the current dev/prototype host. When ready to scale, the move is to a provider with native auto-scaling. VPS30 stays for Ollama, other services, and as a fallback.

### 4.1 Tier 0: Current (VPS30 — Now)

Single node. Good for dev, demos, <500 agents.
Cost: ~€15/mo (Contabo). No redundancy, no auto-scaling.

### 4.2 Tier 1: Production Single-Region (First Paying Customers)

**When:** First 10 paying customers or >500 agents.
**Provider:** Hetzner Cloud (cheapest, EU-native, GDPR) or Fly.io (auto-scale built-in).

```
                    ┌──────────────────┐
                    │  Load Balancer   │
                    │  (Hetzner LB     │
                    │   or Fly proxy)  │
                    │  Sticky WS by    │
                    │  agent_id cookie │
                    └────────┬─────────┘
                             │
                ┌────────────┼────────────┐
                ▼            ▼            ▼
        ┌──────────┐ ┌──────────┐ ┌──────────┐
        │ Hub 1    │ │ Hub 2    │ │ Hub 3    │
        │ (BEAM)   │ │ (BEAM)   │ │ (BEAM)   │
        │ 2C/4GB   │ │ 2C/4GB   │ │ 2C/4GB   │
        └────┬─────┘ └────┬─────┘ └────┬─────┘
             │             │             │
             └── libcluster (DNS strategy) ──┘
                           │
         ┌─────────────────┼─────────────────┐
         ▼                 ▼                 ▼
  ┌─────────────┐  ┌─────────────┐  ┌──────────────┐
  │ Managed     │  │ Managed     │  │ Redpanda     │
  │ Postgres    │  │ Redis       │  │ (3 brokers)  │
  │ Primary +   │  │ Sentinel    │  │ Kafka-compat │
  │ 1 replica   │  │ + replica   │  │ single binary│
  └─────────────┘  └─────────────┘  └──────────────┘
                                    
  ┌─────────────┐  ┌─────────────┐
  │ Cloudflare  │  │ Dedicated   │
  │ R2 (S3)     │  │ GPU node    │
  │ Free egress │  │ (Ollama)    │
  └─────────────┘  └─────────────┘
```

**Key changes from Tier 0:**
- 3 Hub nodes behind LB (BEAM clustering via libcluster DNS strategy)
- Phoenix PubSub adapter: Redis (cross-node message delivery)
- Managed Postgres with replicas
- Managed Redis with sentinel (or Upstash)
- Redpanda instead of Kafka (lighter, Kafka API-compatible, single binary)
- Ollama on dedicated GPU node (separate from Hub)
- S3: Cloudflare R2 (free egress) or Hetzner Object Storage
- Automated PG backups to S3 (daily + WAL archiving)

**Auto-scaling (Hetzner Cloud API or Fly.io native):**

| Metric | Scale Up | Scale Down | Min | Max |
|--------|----------|------------|-----|-----|
| Hub CPU | > 70% for 3min | < 30% for 10min | 2 | 6 |
| Hub connections | > 8K/node | < 2K/node | 2 | 6 |
| Hub memory | > 80% | < 40% | 2 | 6 |

**Estimated cost:** €150-300/mo
**Capacity:** ~5,000 agents, ~200 fleets

**Hetzner auto-scale option:** Use Hetzner Cloud API + custom controller:
```elixir
# Hub.Autoscaler (GenServer, 1-min tick)
# Monitors BEAM telemetry + Prometheus metrics
# Calls Hetzner API to add/remove servers
# Registers new nodes via libcluster
```

**Fly.io auto-scale option:** Native. Just set `min_machines_running` and `auto_stop_machines`:
```toml
# fly.toml
[http_service]
  min_machines_running = 2
  auto_stop_machines = true
  auto_start_machines = true

[http_service.concurrency]
  type = "connections"
  hard_limit = 10000
  soft_limit = 8000
```

---

### 4.3 Tier 2: Auto-Scaling Multi-Region (Growth Phase)

**When:** >1,000 agents or >$5K MRR.
**Provider:** Fly.io (global edge, WebSocket-native) or K8s on AWS/GCP.

```
                         ┌──────────────────┐
                         │   Cloudflare     │
                         │   DNS + CDN      │
                         │   Geo-routing    │
                         └────────┬─────────┘
                                  │
                   ┌──────────────┼──────────────┐
                   ▼                              ▼
          ┌─────────────────┐            ┌─────────────────┐
          │   EU Region     │            │   US Region     │
          │   (primary)     │            │   (secondary)   │
          │                 │            │                 │
          │  Hub 1-N        │            │  Hub N+1-M      │
          │  (auto-scale    │            │  (auto-scale    │
          │   2-10 nodes)   │            │   2-10 nodes)   │
          │                 │            │                 │
          │  Redis Cluster  │◄══════════►│  Redis Cluster  │
          │  Redpanda       │  cross-    │  Redpanda       │
          │  Postgres (RW)  │  region    │  Postgres (RO)  │
          │                 │  repl.     │                 │
          └─────────────────┘            └─────────────────┘
                   │                              │
                   └──────────────┬───────────────┘
                                  ▼
                         ┌─────────────────┐
                         │  Cloudflare R2  │
                         │  (global S3)    │
                         └─────────────────┘
```

**Auto-scaling (Kubernetes HPA):**

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: ringforge-hub-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: ringforge-hub
  minReplicas: 2
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 80
  - type: Pods
    pods:
      metric:
        name: phoenix_channels_connected
      target:
        type: AverageValue
        averageValue: 8000
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 180
      policies:
      - type: Pods
        value: 2
        periodSeconds: 300
    scaleDown:
      stabilizationWindowSeconds: 600
      policies:
      - type: Pods
        value: 1
        periodSeconds: 300
```

**Hub Deployment:**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ringforge-hub
spec:
  replicas: 3
  selector:
    matchLabels:
      app: ringforge-hub
  template:
    spec:
      containers:
      - name: hub
        image: ringforge/hub:latest
        ports:
        - containerPort: 4000
        resources:
          requests:
            cpu: "500m"
            memory: "512Mi"
          limits:
            cpu: "2000m"
            memory: "2Gi"
        env:
        - name: PHX_HOST
          value: "hub.ringforge.io"
        - name: DATABASE_URL
          valueFrom:
            secretKeyRef:
              name: ringforge-secrets
              key: database-url
        - name: REDIS_URL
          valueFrom:
            secretKeyRef:
              name: ringforge-secrets
              key: redis-url
        - name: RELEASE_COOKIE
          valueFrom:
            secretKeyRef:
              name: ringforge-secrets
              key: erlang-cookie
        livenessProbe:
          httpGet:
            path: /api/health
            port: 4000
          initialDelaySeconds: 15
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /api/health
            port: 4000
          initialDelaySeconds: 5
          periodSeconds: 5
```

**Estimated cost:** €500-2,000/mo
**Capacity:** ~100,000 agents, ~5,000 fleets

---

### 4.4 Tier 3: Enterprise Scale (Year 2+)

Additions over Tier 2:
- Dedicated K8s clusters per enterprise tenant
- CockroachDB or Citus for globally distributed Postgres
- Dedicated GPU pools per region (vLLM for production inference)
- Private VPC peering for enterprise customers
- Custom domains (fleet.customer.com)
- 99.99% SLA with multi-AZ
- SOC 2 Type II compliance

**Estimated cost:** €5,000-20,000/mo
**Capacity:** Unlimited (horizontal scaling)

---

### 4.5 Provider Comparison

| | Hetzner Cloud | Fly.io | AWS (EKS) | GCP (GKE) |
|---|---|---|---|---|
| **3x Hub nodes (2C/4GB)** | €36/mo | $45/mo | $100/mo | $90/mo |
| **Managed Postgres** | €15/mo | Neon ~$20/mo | $50/mo (RDS) | $40/mo |
| **Redis** | Upstash ~$10/mo | Upstash ~$10/mo | $30/mo | $25/mo |
| **S3 storage** | €5/mo | R2 free tier | $5/mo | $5/mo |
| **Load balancer** | €6/mo | Included | $20/mo | $18/mo |
| **GPU (Ollama)** | €50/mo | $100/mo | $200/mo | $150/mo |
| **Total** | **~€120/mo** | **~$180/mo** | **~$400/mo** | **~$330/mo** |
| **Auto-scale** | API + custom | ✅ Native | ✅ HPA | ✅ HPA |
| **Global edge** | ❌ EU only | ✅ 35 regions | ✅ | ✅ |
| **WebSocket** | ✅ | ✅ Native | ✅ ALB | ✅ |
| **GDPR** | ✅ German DC | ❌ US entity | ⚠️ Config needed | ⚠️ Config needed |

**Recommended path:**
1. **Start (Tier 1):** Hetzner Cloud — cheapest, EU-native, GDPR-compliant, API for custom auto-scaling
2. **Scale (Tier 2):** Fly.io — global edge, native auto-scale, WebSocket-first, zero-config clustering
3. **Enterprise (Tier 3):** AWS/GCP — compliance, enterprise customers expect it, managed K8s

---

### 4.6 BEAM Clustering Strategy

The BEAM VM clusters natively. This is Ringforge's scaling superpower.

**Single-region (libcluster DNS):**
```elixir
config :libcluster,
  topologies: [
    ringforge: [
      strategy: Cluster.Strategy.DNSPoll,
      config: [
        polling_interval: 5_000,
        query: "ringforge-hub.internal",
        node_basename: "hub"
      ]
    ]
  ]
```

**Multi-region (libcluster + Phoenix PubSub Redis):**
```elixir
# Cross-node PubSub via Redis (not pg2, which is region-local)
config :hub, Hub.PubSub,
  adapter: Phoenix.PubSub.Redis,
  url: "redis://redis-cluster.internal:6379"
```

**WebSocket stickiness:**
- LB sticky sessions by `agent_id` cookie
- Agent reconnects always land on same Hub node (until failover)
- On node failure: agent reconnects → LB routes to another node → presence re-registers → event replay fills gap

---

### 4.7 Dockerization for Deploy

**Before any Tier 1 migration:**

```dockerfile
# hub/Dockerfile
FROM elixir:1.18-otp-27-alpine AS build

RUN apk add --no-cache build-base git
WORKDIR /app

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN MIX_ENV=prod mix deps.compile

COPY config config
COPY lib lib
COPY priv priv
COPY assets assets

RUN MIX_ENV=prod mix assets.deploy
RUN MIX_ENV=prod mix release

FROM alpine:3.19 AS app
RUN apk add --no-cache libstdc++ openssl ncurses-libs

WORKDIR /app
COPY --from=build /app/_build/prod/rel/hub ./

ENV PHX_SERVER=true
EXPOSE 4000

CMD ["bin/hub", "start"]
```

```yaml
# docker-compose.prod.yml
services:
  hub:
    build: ./hub
    environment:
      - DATABASE_URL=${DATABASE_URL}
      - REDIS_URL=${REDIS_URL}
      - SECRET_KEY_BASE=${SECRET_KEY_BASE}
      - PHX_HOST=${PHX_HOST}
      - RELEASE_COOKIE=${RELEASE_COOKIE}
    ports:
      - "4000:4000"
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://localhost:4000/api/health"]
      interval: 10s
      timeout: 5s
      retries: 3
```

---

## 5. Security Architecture

### 5.1 Authentication Layers

```
Layer 1: Transport
  └─ TLS 1.3 (Cloudflare → Hub), WSS only, HSTS

Layer 2: API Key (first connection)
  └─ rf_live_xxx, SHA-256 hashed in DB
  └─ Key type scoping (live/test/admin)
  └─ Rate limited: 5 auth attempts/min/IP

Layer 3: Ed25519 (reconnection)
  └─ Challenge-response, no credentials on wire
  └─ 32-byte random challenge per attempt
  └─ Key rotation support

Layer 4: Session (dashboard)
  └─ Plug.Session (secure cookie, httpOnly, 24h max_age)
  └─ CSRF on all forms
  └─ bcrypt password hashing
```

### 5.2 Tenant Isolation (The Cardinal Rule)

**Tenant A can never see, access, or affect Tenant B.**

| Resource | Isolation Method |
|----------|-----------------|
| WebSocket | Socket assigns carry `tenant_id`; all operations scoped |
| Fleet channel | Topic = `fleet:{fleet_id}`; join checks tenant match |
| Database | All queries include `WHERE tenant_id = $1` |
| Redis | Key prefix: `rf:{tenant_id}:...` |
| Kafka | Topic per fleet: `rf.{fleet_id}.activity` |
| S3 | Path prefix: `tenants/{tenant_id}/` |
| Tasks | TaskRouter only searches agents in same fleet |
| Memory | Fleet-scoped (fleet_id in all operations) |

**CI enforcement:** Automated "tenant isolation" test suite that creates 2 tenants, has Agent A1 try every operation targeting Tenant B — all must fail.

### 5.3 Rate Limiting

| Scope | Limit | Enforcement |
|-------|-------|-------------|
| Auth attempts (per IP) | 5/min | Plug middleware |
| WebSocket connections (per tenant) | Plan-based | Quota.check on join |
| Messages (per agent) | 100/min | FleetChannel check |
| Messages (per tenant) | Plan-based daily | Quota counter |
| Task submissions (per agent) | 20/min | FleetChannel check |
| API requests (per key) | 60/min | Plug middleware |
| Memory writes (per agent) | 50/min | FleetChannel check |

```elixir
defmodule Hub.RateLimit do
  def check(key, opts) do
    limit = Keyword.fetch!(opts, :limit)
    window = Keyword.fetch!(opts, :window_seconds)
    
    case Redix.command(:rate_limit, ["INCR", key]) do
      {:ok, 1} ->
        Redix.command(:rate_limit, ["EXPIRE", key, window])
        :ok
      {:ok, count} when count <= limit ->
        :ok
      {:ok, _} ->
        ttl = Redix.command!(:rate_limit, ["TTL", key])
        {:error, :rate_limited, ttl}
    end
  end
end
```

### 5.4 Input Validation

| Input | Validation |
|-------|-----------|
| Agent name | Max 100 chars, UTF-8, no control chars |
| Memory key | Max 500 chars, ASCII printable |
| Memory value | Max 1MB |
| Activity description | Max 10,000 chars |
| Task prompt | Max 50,000 chars |
| Tags | Max 20 per item, max 50 chars each |
| File size | Per plan (1GB free, 25GB pro) |
| Message payload | Max 100KB |
| WebSocket frame | Max 1MB |

### 5.5 Secrets Management

**Current (Tier 0):** Environment variables via `.env` (mode 600).

**Tier 1:** Continue env vars, but secrets injected via CI/CD pipeline. No secrets in source.

**Tier 2+:** HashiCorp Vault or AWS Secrets Manager. Injected via K8s secrets with auto-rotation.

| Secret | Storage | Rotation |
|--------|---------|----------|
| API keys | SHA-256 hashed in Postgres | Tenant-controlled via dashboard |
| Ed25519 private keys | Agent-local (never sent to Hub) | Agent-controlled |
| DB password | Env var → Vault (Tier 2) | On deploy / auto-rotate |
| Redis password | Env var → Vault (Tier 2) | On deploy / auto-rotate |
| Stripe secret | Env var → Vault (Tier 2) | Via Stripe dashboard |
| Session signing | `SECRET_KEY_BASE` env var | On deploy |

### 5.6 Audit Trail

Every sensitive action → Kafka `rf.{fleet}.audit` topic (365d retention).

```json
{
  "timestamp": "2026-02-07T18:30:00Z",
  "action": "agent.registered",
  "tenant_id": "xxx",
  "actor": "api_key:rf_live_xxx",
  "target": "agent:ag_xxx",
  "ip": "1.2.3.4",
  "metadata": {"framework": "openclaw", "capabilities": ["code"]}
}
```

**Audited actions:** tenant registration/login, API key CRUD, agent registration/deregistration, agent kick, fleet CRUD, plan changes, quota overrides.

### 5.7 Security Hardening Status

**Done (2026-02-07 audit):**
- [x] Agent hijacking fix (reconnect now requires auth)
- [x] Metrics endpoint auth'd
- [x] Garage S3 ports blocked from outside
- [x] Hardcoded secrets replaced with env vars
- [x] Health endpoint info leak fixed
- [x] BEAM gossip bound to localhost
- [x] LiveView check_origin restricted
- [x] Session cookie secured (httpOnly, secure, max_age)
- [x] Group authorization (owner-only dissolve)
- [x] Request body size limit (1MB)
- [x] SSH hardened (MaxAuthTries=3, no X11/Agent forwarding)
- [x] Fail2ban (4 jails)
- [x] HSTS, security headers, CSP

**Before Tier 1 launch:**
- [ ] Per-agent rate limiting (FleetChannel)
- [ ] Input validation on all FleetChannel handlers
- [ ] Structured audit logging (Kafka)
- [ ] Automated PG backups with encryption
- [ ] Content Security Policy headers (tighten)
- [ ] Dependency audit (`mix audit`)
- [ ] WebSocket frame size limit enforcement

**Before Tier 2:**
- [ ] mTLS between services (Hub ↔ Postgres ↔ Redis ↔ Redpanda)
- [ ] K8s network policies (pod-to-pod isolation)
- [ ] Secrets in Vault/KMS
- [ ] Dependabot for auto dependency updates
- [ ] External penetration test
- [ ] OWASP Top 10 review
- [ ] SOC 2 Type I readiness assessment

---

## 6. Data Architecture

### 6.1 What Goes Where

| Data Type | Hot Storage | Cold Storage | TTL |
|-----------|-------------|--------------|-----|
| Tenant/Fleet/Agent | Postgres | — | Forever |
| API keys (hashed) | Postgres | — | Until revoked |
| Presence state | ETS + Phoenix.Presence | — | Until disconnect |
| Active tasks | Redis | — | Task TTL (30s-5min) |
| Task history | Redis (last 1000) | Kafka | Per plan |
| Memory entries | Redis | Kafka (compacted) | Until deleted |
| Activity events | Redis (last 1000) | Kafka | Per plan |
| DMs (queued) | Redis | — | 5 min delivery window |
| DM history | Kafka | S3 (archived) | Per plan |
| Files | S3 | S3 (lifecycle) | Until deleted |
| Audit trail | Kafka | S3 (archived) | 365 days |
| Metrics | Prometheus | Grafana | 30 days |

### 6.2 Backup Strategy

| Data | Method | Frequency | Retention | Location |
|------|--------|-----------|-----------|----------|
| Postgres | pg_dump + WAL archiving | Hourly + continuous | 30 days | S3/R2 |
| Redis | RDB snapshots | Every 5 min | 7 days | S3/R2 |
| Kafka/Redpanda | Topic replication (RF=3) | Continuous | Per plan | — |
| S3 files | Cross-region replication (Tier 2+) | Continuous | — | 2nd region |

### 6.3 Data Residency (GDPR)

- Default region: EU (Hetzner Falkenstein / Nuremberg)
- Tenant chooses region at registration (Tier 2+)
- Data never leaves chosen region
- `tenant.delete` cascades: Postgres FK + Kafka tombstones + S3 lifecycle

---

## 7. Observability

### 7.1 Metrics Stack

```
Hub (telemetry) → Prometheus → Grafana
Redpanda metrics → Prometheus → Grafana
Redis metrics → Prometheus → Grafana
Postgres metrics → Prometheus → Grafana
```

**Dashboards:**
1. **Fleet Overview:** Connected agents, message rates, memory usage, task throughput
2. **Per-Tenant:** Usage vs quotas, growth trends, billing health
3. **Task Orchestration:** Route times, completion rates, worker utilization, queue depth
4. **Infrastructure:** CPU/RAM/disk/network per node, DB connections, Redis memory
5. **Errors:** Auth failures, quota hits, WebSocket drops, task timeouts

### 7.2 Alerting

| Alert | Condition | Severity |
|-------|-----------|----------|
| Hub node down | Health check fails 3x | Critical |
| Postgres > 80% connections | Pool exhaustion risk | Warning |
| Redis memory > 90% | Eviction risk | Warning |
| Kafka lag > 10K | Consumer falling behind | Warning |
| Auth failure spike | > 50 failures/min | Critical |
| Task timeout rate > 10% | Workers overwhelmed | Warning |
| Error rate > 5% | General degradation | Warning |

### 7.3 Structured Logging

```elixir
Logger.info("Task routed",
  tenant_id: task.fleet_id,
  task_id: task.task_id,
  agent_id: task.assigned_to,
  route_time_ms: route_time,
  capabilities: task.capabilities_required
)
```

Log aggregation: Loki (self-host Tier 1) → Datadog/Betterstack (managed Tier 2+).

---

## 8. Migration Playbook

### 8.1 VPS30 → Tier 1 (Trigger: First 10 Paying Customers)

**Pre-migration (do now):**
1. Dockerize the Hub (Dockerfile + docker-compose.prod.yml) ← ready above
2. Automated PG backups to S3 (cron + pg_dump)
3. Test BEAM clustering locally (3 Hub nodes, single machine)
4. DNS plan: ringforge.wejoona.com → hub.ringforge.io

**Migration day:**
1. Deploy 3 Hub nodes on Hetzner Cloud (2C/4GB each)
2. Provision managed Postgres (Hetzner/Neon)
3. Migrate data: `pg_dump` → managed Postgres
4. Provision managed Redis (Upstash or Hetzner)
5. Deploy Redpanda cluster (3 nodes)
6. Configure libcluster (DNS strategy)
7. Smoke test: presence, DMs, tasks, memory, dashboard
8. Switch Cloudflare DNS to new LB
9. Monitor 48h
10. Keep VPS30 for Ollama + other services

**Rollback:** DNS switch back to VPS30 (< 5 min).

### 8.2 Tier 1 → Tier 2 (Trigger: >1,000 Agents or >$5K MRR)

1. Deploy Kubernetes cluster (or Fly.io machines)
2. Helm chart for Hub deployment
3. HPA configured (CPU + connections + custom metrics)
4. Add US region
5. Cross-region Postgres replication (logical)
6. Cloudflare geo-routing
7. Canary deployments (10% → 50% → 100%)

### 8.3 Key Decisions That Enable Scaling

| Decision | Why It Matters |
|----------|---------------|
| BEAM/OTP | Native clustering, millions of lightweight processes, hot code upgrades |
| Phoenix PubSub + Redis adapter | Cross-node message delivery without custom plumbing |
| Custom JSON envelope (not Phoenix-native) | Protocol is transport-independent — can leave Phoenix later |
| Kafka/Redpanda EventBus | Durable events, multi-consumer, replay across nodes |
| Tenant isolation from day 1 | No data model migration needed for multi-tenant scale |
| Stateless Hub (tasks in Redis, events in Kafka) | Any Hub node can handle any request — true horizontal scaling |

---

*"Build for 10, design for 10,000, plan for 1,000,000."*

*Created: 2026-02-07 by Onyx Key | Updated: 2026-02-07 v2 (new direction alignment)*
