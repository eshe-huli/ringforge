# Ringforge Roadmap

## Vision
Full SaaS platform for AI agent fleet coordination. Stripe billing, social logins,
cloud provider integrations, agent creation from dashboard.

---

## ✅ Completed (Phases 1–7)

| Phase | Feature | Status |
|-------|---------|--------|
| 1 | Agent Identity & Auth (Ed25519, API keys, Ecto) | ✅ |
| 2 | Fleet Channel & Presence (Phoenix Presence) | ✅ |
| 3 | Activity Broadcast + EventBus behaviour | ✅ |
| 4 | Shared Memory (CRUD, query, subscriptions) | ✅ |
| 5 | Direct Messaging + Event Replay | ✅ |
| 6 | Admin REST API + Quotas | ✅ |
| 7 | LiveView Dashboard (6 pages, SaladUI) | ✅ |
| — | Security Hardening (2026-02-07 audit) | ✅ |

---

## 🚧 Phase 8 — SDKs & Idempotency

### 8.1 TypeScript SDK (`@ringforge/sdk`)
- [x] Repo created: `eshe-huli/ringforge-sdk` (private)
- [x] Types, client, sub-APIs (presence, activity, memory, DM, groups)
- [x] Client-side idempotency (cache with TTL)
- [ ] Server-side idempotency (Hub stores idempotency keys in ETS, returns cached response)
- [ ] Fleet channel auto-join (resolve fleet from API key server-side)
- [ ] npm publish pipeline
- [ ] Integration tests against live hub

### 8.2 Python SDK (`ringforge`)
- [ ] websockets + asyncio client
- [ ] Same API surface as TypeScript
- [ ] PyPI publish pipeline

### 8.3 Elixir SDK (`ringforge`)
- [ ] Phoenix Channel client
- [ ] Hex publish pipeline

### 8.4 Server-Side Idempotency
- [ ] ETS table `hub_idempotency` — `{key, response, expires_at}`
- [ ] FleetChannel extracts `_idempotency_key` from payload
- [ ] Before processing: check cache → return cached if hit
- [ ] After processing: store result with 5-min TTL
- [ ] Applies to: `activity:broadcast`, `memory:set`, `direct:send`, `group:create`

---

## 📋 Phase 9 — File Distribution (Garage/S3)

- [ ] Presigned upload URL endpoint (Hub → Garage)
- [ ] Presigned download URL endpoint
- [ ] File metadata in Rust store
- [ ] SDK methods: `client.files.upload()`, `client.files.download()`
- [ ] Dashboard file browser page
- [ ] Per-tenant storage quotas

---

## 📋 Phase 10 — Production EventBus (Kafka)

- [ ] Switch default from `Hub.EventBus.Local` to `Hub.EventBus.Kafka`
- [ ] Kafka topic auto-creation per fleet
- [ ] Event retention policy (7d default, configurable per plan)
- [ ] Backpressure handling
- [ ] Consumer group for multi-node hub

---

## 📋 Phase 11 — Full Auth & Ed25519 Flow

- [ ] Challenge-response wired end-to-end in Socket registration
- [ ] SDK: auto-generate Ed25519 keypair, store in config
- [ ] SDK: sign challenge on reconnect (no API key on wire after first auth)
- [ ] Key rotation support
- [ ] Dashboard: agent public key display

---

## 📋 Phase 12 — SaaS Billing (Stripe)

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

## 📋 Phase 13 — Invite-Only + Social Login

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

## 📋 Phase 14 — Webhooks & Callbacks

- [ ] Webhook endpoint registration (URL, events, secret)
- [ ] HMAC-SHA256 signed payloads
- [ ] Retry with exponential backoff (3 attempts)
- [ ] Event types: agent.connected, agent.disconnected, message.received, activity.broadcast, memory.changed
- [ ] Dashboard webhook management page
- [ ] Webhook delivery logs

---

## 📋 Phase 15 — Agent Creation from Dashboard

### Cloud Provider Integrations
- [ ] Contabo API (VPS provisioning)
- [ ] Hetzner API
- [ ] DigitalOcean API
- [ ] AWS EC2 / Lightsail
- [ ] Provider credentials management (encrypted, per-tenant)

### Agent Provisioning
- [ ] "Create Agent" wizard in dashboard
- [ ] Template selection (OpenClaw agent, custom, bare)
- [ ] One-click deploy: spin VPS → install agent → connect to fleet
- [ ] Agent health monitoring from dashboard
- [ ] SSH key management
- [ ] Cost tracking per agent (provider billing passthrough)

---

## 📋 Phase 16 — Capability Matching & Task Routing

- [ ] Task queue with capability requirements
- [ ] Auto-routing: match task → agent with required capabilities + lowest load
- [ ] Priority queuing
- [ ] Task timeout + reassignment
- [ ] Dashboard task board view

---

## 📋 Phase 17 — Observability

- [ ] Grafana dashboards (Ringforge-specific)
  - Fleet overview (connected agents, message rates, memory usage)
  - Per-tenant usage
  - Error rates, latency percentiles
- [ ] Alert rules (agent disconnected, quota near limit, error spike)
- [ ] Dashboard: embedded metrics charts (inline, no Grafana redirect)

---

## 📋 Phase 18 — Multi-Region & Clustering

- [ ] libcluster with DNS strategy (replace gossip)
- [ ] Multi-node hub deployment
- [ ] Region-aware agent routing
- [ ] Conflict resolution for distributed memory
- [ ] Helm chart for Kubernetes deployment

---

## 📋 Phase 19 — Pulsar EventBus

- [ ] `Hub.EventBus.Pulsar` implementation
- [ ] Config swap: one line change
- [ ] Pulsar Functions for event processing

---

## 📋 Phase 20 — Full Security Audit

- [ ] Penetration testing
- [ ] OWASP Top 10 review
- [ ] Rate limiting per-agent WebSocket
- [ ] Input validation hardening
- [ ] Audit logging (who did what, when)
- [ ] SOC 2 readiness checklist
- [ ] LUKS disk encryption

---

## Priority Order

1. **Phase 8** — SDKs + Idempotency (agents can't use Ringforge without this)
2. **Phase 12** — Stripe billing (SaaS can't charge without this)
3. **Phase 13** — Auth (social login + invite = user acquisition)
4. **Phase 11** — Full Ed25519 flow (security foundation)
5. **Phase 9** — File distribution (frequently requested)
6. **Phase 10** — Kafka production (data durability)
7. **Phase 14** — Webhooks (integration point)
8. **Phase 15** — Agent creation from dashboard (differentiator)
9. **Phase 16** — Task routing (agent orchestration)
10. **Phase 17** — Observability (ops maturity)
11. **Phase 18-20** — Scale & audit

---

*Created: 2026-02-07 by Onyx Key*
