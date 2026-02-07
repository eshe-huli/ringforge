# Ringforge Roadmap

## Vision
Full SaaS platform for AI agent fleet coordination and task orchestration. Stripe billing, social logins,
cloud provider integrations, agent creation from dashboard.

---

## ✅ Completed (Phases 1–8)

| Phase | Feature | Status |
|-------|---------|--------|
| 1 | Agent Identity & Auth (Ed25519, API keys, Ecto) | ✅ |
| 2 | Fleet Channel & Presence (Phoenix Presence) | ✅ |
| 3 | Activity Broadcast + EventBus behaviour | ✅ |
| 4 | Shared Memory (CRUD, query, subscriptions) | ✅ |
| 5 | Direct Messaging + Event Replay | ✅ |
| 6 | Admin REST API + Quotas | ✅ |
| 7 | LiveView Dashboard (6 pages, SaladUI) + Add Agent Wizard | ✅ |
| — | Security Hardening (2026-02-07 audit) | ✅ |
| — | Server-side idempotency (ETS, fleet_channel.ex) | ✅ |
| — | Fleet:lobby auto-join | ✅ |
| 8 | Task Orchestration & Capability Routing | ✅ |

### Phase 7 Addition — Add Agent Wizard (2026-02-07)
- [x] Dashboard "Add Agent" wizard (`dashboard_live.ex`)
- [x] Dead-simple onboarding for vibecoders and non-tech users

### Phase 8 Details — Task Orchestration (2026-02-07)
- [x] `Hub.Task` — ETS-backed task store
- [x] `Hub.TaskRouter` — Capability-based matching (route to best agent by capabilities + load)
- [x] `Hub.TaskSupervisor` — GenServer orchestrator (1s tick, task lifecycle)
- [x] `Hub.Workers.OllamaBridge` — Virtual agents for local Ollama models
- [x] Wire protocol: `task:submit`, `task:claim`, `task:result`, `task:status`
- [x] Two Ollama workers: `qwen2.5-coder:7b`, `llama3.1:8b` (fleet peers, not tools)

### TypeScript SDK (built during Phase 7-8)
- [x] Repo created: `eshe-huli/ringforge-sdk` (private)
- [x] Types, client, sub-APIs (presence, activity, memory, DM, groups)
- [x] Client-side idempotency (cache with TTL)

---

## 🚧 Phase 9 — SDK Publishing & Polish

### 9.1 TypeScript SDK npm publish
- [ ] npm publish pipeline (`@ringforge/sdk`)
- [ ] Integration tests against live hub
- [ ] README + API docs

### 9.2 Python SDK (`ringforge`)
- [ ] websockets + asyncio client
- [ ] Same API surface as TypeScript
- [ ] PyPI publish pipeline

### 9.3 Elixir SDK (`ringforge`)
- [ ] Phoenix Channel client
- [ ] Hex publish pipeline

---

## 📋 Phase 10 — OpenClaw RingForge Plugin

- [ ] Argus-side plugin: auto-connect to RingForge hub on startup
- [ ] Presence sync (OpenClaw agent state → RingForge presence)
- [ ] DM injection (RingForge DMs → agent turns)
- [ ] Task claim/result hooks
- [ ] Config: `ringforge.enabled`, `ringforge.apiKey`, `ringforge.server`

---

## 📋 Phase 11 — File Distribution (Garage/S3)

- [ ] Presigned upload URL endpoint (Hub → Garage)
- [ ] Presigned download URL endpoint
- [ ] File metadata in Rust store
- [ ] SDK methods: `client.files.upload()`, `client.files.download()`
- [ ] Dashboard file browser page
- [ ] Per-tenant storage quotas

---

## 📋 Phase 12 — Production EventBus (Kafka)

- [ ] Switch default from `Hub.EventBus.Local` to `Hub.EventBus.Kafka`
- [ ] Kafka topic auto-creation per fleet
- [ ] Event retention policy (7d default, configurable per plan)
- [ ] Backpressure handling
- [ ] Consumer group for multi-node hub

---

## 📋 Phase 13 — Full Auth & Ed25519 Flow

- [ ] Challenge-response wired end-to-end in Socket registration
- [ ] SDK: auto-generate Ed25519 keypair, store in config
- [ ] SDK: sign challenge on reconnect (no API key on wire after first auth)
- [ ] Key rotation support
- [ ] Dashboard: agent public key display

---

## 📋 Phase 14 — SaaS Billing (Stripe)

### Plans (benchmarked against industry)

| | Free | Pro ($29/mo) | Scale ($99/mo) | Enterprise (custom) |
|---|---|---|---|---|
| Agents | 10 | 100 | 1,000 | Unlimited |
| Messages/day | 50K | 500K | 5M | Unlimited |
| Memory entries | 5K | 100K | 1M | Unlimited |
| Fleets | 1 | 5 | 25 | Unlimited |
| File storage | 1 GB | 25 GB | 250 GB | Custom |
| Event retention | 24h | 7d | 30d | 90d+ |
| Support | Community | Email | Priority | Dedicated |
| SSO/SAML | ❌ | ❌ | ✅ | ✅ |
| Webhooks | ❌ | ✅ | ✅ | ✅ |
| Audit logs | ❌ | ❌ | ✅ | ✅ |

### Implementation
- [ ] Stripe integration (Checkout, Customer Portal, Webhooks)
- [ ] `stripe_customer_id` on Tenant schema
- [ ] `subscription` schema (plan, status, period_end, stripe_subscription_id)
- [ ] Webhook handler: `invoice.paid`, `customer.subscription.updated/deleted`
- [ ] Plan upgrade/downgrade with proration
- [ ] Usage-based billing option (per-message overage)
- [ ] Dashboard billing page (current plan, usage, invoices, upgrade button)
- [ ] Trial period (14 days Pro)
- [ ] Quota enforcement synced with Stripe subscription state

---

## 📋 Phase 15 — Invite-Only + Social Login

### Registration
- [ ] Invite code system (admin generates codes, limited uses)
- [ ] Waitlist mode (email capture → manual approval)
- [ ] Self-serve toggle once launched

### Social Login
- [ ] Google OAuth2
- [ ] GitHub OAuth2
- [ ] Optional 2FA (TOTP — Google Authenticator compatible)
- [ ] Magic link email login
- [ ] Dashboard: connected accounts management

---

## 📋 Phase 16 — Webhooks & Callbacks

- [ ] Webhook endpoint registration (URL, events, secret)
- [ ] HMAC-SHA256 signed payloads
- [ ] Retry with exponential backoff (3 attempts)
- [ ] Event types: agent.connected, agent.disconnected, message.received, activity.broadcast, memory.changed
- [ ] Dashboard webhook management page
- [ ] Webhook delivery logs

---

## 📋 Phase 17 — Agent Provisioning from Dashboard

### Cloud Provider Integrations
- [ ] Contabo API (VPS provisioning)
- [ ] Hetzner API
- [ ] DigitalOcean API
- [ ] AWS EC2 / Lightsail
- [ ] Provider credentials management (encrypted, per-tenant)

### Agent Provisioning
- [ ] Template selection (OpenClaw agent, custom, bare)
- [ ] One-click deploy: spin VPS → install agent → connect to fleet
- [ ] Agent health monitoring from dashboard
- [ ] SSH key management
- [ ] Cost tracking per agent (provider billing passthrough)

---

## 📋 Phase 18 — Agent Naming & Persistence Improvements

- [ ] Persistent agent names across reconnections
- [ ] Agent profiles (avatar, description, tags)
- [ ] Session history and continuity
- [ ] Agent migration between fleets

---

## 📋 Phase 19 — Observability

- [ ] Grafana dashboards (Ringforge-specific)
  - Fleet overview (connected agents, message rates, memory usage)
  - Per-tenant usage
  - Error rates, latency percentiles
- [ ] Alert rules (agent disconnected, quota near limit, error spike)
- [ ] Dashboard: embedded metrics charts (inline, no Grafana redirect)

---

## 📋 Phase 20 — Multi-Region & Clustering

- [ ] libcluster with DNS strategy (replace gossip)
- [ ] Multi-node hub deployment
- [ ] Region-aware agent routing
- [ ] Conflict resolution for distributed memory
- [ ] Helm chart for Kubernetes deployment

---

## 📋 Phase 21 — Domotic / IoT Support

- [ ] Lightweight agent protocol for embedded devices
- [ ] Sensor data ingestion via fleet memory
- [ ] Device presence and health monitoring
- [ ] Home automation integrations (MQTT bridge)
- [ ] Dashboard device view

---

## 📋 Phase 22 — Pulsar EventBus

- [ ] `Hub.EventBus.Pulsar` implementation
- [ ] Config swap: one line change
- [ ] Pulsar Functions for event processing

---

## 📋 Phase 23 — Full Security Audit

- [ ] Penetration testing
- [ ] OWASP Top 10 review
- [ ] Rate limiting per-agent WebSocket
- [ ] Input validation hardening
- [ ] Audit logging (who did what, when)
- [ ] SOC 2 readiness checklist
- [ ] LUKS disk encryption

---

## Priority Order

1. **Phase 9** — SDK publish (agents need packages to connect)
2. **Phase 10** — OpenClaw plugin (Argus connects to mesh)
3. **Phase 14** — Stripe billing (SaaS can't charge without this)
4. **Phase 15** — Auth (social login + invite = user acquisition)
5. **Phase 13** — Full Ed25519 flow (security foundation)
6. **Phase 11** — File distribution (frequently requested)
7. **Phase 12** — Kafka production (data durability)
8. **Phase 16** — Webhooks (integration point)
9. **Phase 17** — Agent provisioning from dashboard (differentiator)
10. **Phase 18** — Agent naming & persistence
11. **Phase 19** — Observability (ops maturity)
12. **Phase 20-23** — Scale, IoT, audit

---

*Created: 2026-02-07 by Onyx Key | Updated: 2026-02-07 (Phase 8 complete)*
