# RingForge — Execution Plan

> **Created:** 2026-02-07
> **Author:** Ben Ouattara + Onyx Key
> **Status:** Active
> **Goal:** From working prototype → paying customers in 90 days

---

## Where We Are (2026-02-07)

**Built & running on VPS30:**
- Hub (Elixir/OTP) with 8 phases complete
- Task orchestration with Ollama workers (qwen2.5-coder:7b, llama3.1:8b)
- LiveView dashboard with Add Agent wizard
- Auth (email/password + API key), quotas, presence, DMs, memory, groups, replay
- TypeScript SDK (repo, not published)
- Domain: ringforge.wejoona.com

**What's missing for launch:**
- Published SDKs (npm, pypi)
- OpenClaw plugin (the first real integration)
- Landing page / marketing site
- Stripe billing
- Documentation site
- Community presence

---

## The 90-Day Sprint

### 🔴 Sprint 1: "People Can Connect" (Weeks 1-3)
*Goal: Anyone can connect an agent to RingForge in under 5 minutes.*

| Week | Task | Owner | Deliverable |
|------|------|-------|-------------|
| W1 | TypeScript SDK polish + publish | Onyx | `@ringforge/sdk` on npm |
| W1 | Python SDK build + publish | Onyx | `ringforge` on PyPI |
| W1 | CLI quick-connect tool | Onyx | `npx ringforge-connect --key xxx` |
| W2 | OpenClaw RingForge plugin | Argus+Onyx | Plugin in openclaw config |
| W2 | SDK docs site (Mintlify/Docusaurus) | Onyx | docs.ringforge.io |
| W3 | Integration tests (SDK → live hub) | Onyx | CI green |
| W3 | "Hello Fleet" tutorial | Ben/Onyx | Blog post / doc |

**Success metric:** 3 different frameworks can connect to RingForge (OpenClaw, raw Python, raw Node.js).

### 🟡 Sprint 2: "People Can Pay" (Weeks 4-6)
*Goal: Stripe billing live. Free tier → Pro tier upgrade path.*

| Week | Task | Owner | Deliverable |
|------|------|-------|-------------|
| W4 | Landing page (ringforge.io) | Onyx | Hero, features, pricing, signup |
| W4 | Stripe integration (Checkout + Portal) | Onyx | Billing flows |
| W5 | Subscription schema + webhook handlers | Onyx | Plan enforcement |
| W5 | Dashboard billing page | Onyx | Upgrade/downgrade UI |
| W6 | Invite code system | Onyx | Controlled early access |
| W6 | GitHub OAuth | Onyx | Devs can sign up with GitHub |

**Success metric:** First paying customer (even if it's a test account). Billing flows work end-to-end.

### 🟢 Sprint 3: "People Talk About It" (Weeks 7-9)
*Goal: Public launch to developer community.*

| Week | Task | Owner | Deliverable |
|------|------|-------|-------------|
| W7 | Launch blog post | Ben | "I built an agent mesh" |
| W7 | Twitter/X thread + demo video | Ben | Viral-worthy demo |
| W7 | Hacker News Show HN | Ben | Show HN: RingForge |
| W8 | Discord community setup | Onyx | discord.gg/ringforge |
| W8 | GitHub repo public (hub + SDKs) | Ben | Open source the hub |
| W8 | Dev.to / Reddit posts | Ben | r/artificial, r/LocalLLaMA |
| W9 | First 10 external users supported | Both | Real feedback loop |
| W9 | Iterate based on feedback | Both | Bug fixes, DX improvements |

**Success metric:** 50+ GitHub stars, 10+ registered users, 3+ active fleets from strangers.

### 🔵 Sprint 4: "It's Real" (Weeks 10-12)
*Goal: Product-market fit signals. Features that retain users.*

| Week | Task | Owner | Deliverable |
|------|------|-------|-------------|
| W10 | Webhooks (Phase 16) | Onyx | External integrations |
| W10 | File distribution (Phase 11) | Onyx | Agent file sharing |
| W11 | Dashboard polish (mobile, UX) | Onyx | Vibecoder-friendly |
| W11 | Agent templates / marketplace preview | Onyx | One-click agent recipes |
| W12 | Kafka production EventBus | Onyx | Data durability |
| W12 | Usage analytics + retention metrics | Onyx | Know what's working |

**Success metric:** 5+ paid users, 50+ weekly active agents, NPS > 40.

---

## Revenue Milestones

| Milestone | Target | When |
|-----------|--------|------|
| First signup | 1 registered user (non-Ben) | Week 3 |
| First fleet | 1 external fleet with 2+ agents | Week 5 |
| First dollar | 1 paid subscription ($29) | Week 7 |
| $1K MRR | ~35 Pro or ~10 Scale customers | Month 4-5 |
| $5K MRR | ~170 Pro or ~50 Scale customers | Month 6-8 |
| $10K MRR | Mix of Pro + Scale + Enterprise | Month 9-12 |

---

## Go-To-Market Strategy

### Positioning
> **"The missing infrastructure layer for AI agent teams."**
> Connect any agent to the mesh. Get presence, messaging, memory, and task routing. Under 10 lines of code.

### Channels (Priority Order)

1. **GitHub + Open Source**
   - Open-source the hub (Apache 2.0)
   - SDKs are MIT
   - Self-host option is the funnel → cloud is the monetization
   - This is the Redis/Kafka/Temporal playbook

2. **Developer Content**
   - "How I built an agent mesh" blog post (Ben's story)
   - "Connect 2 AI agents in 5 minutes" tutorial
   - "Local LLMs as fleet agents" (Ollama demo — this is the hook)
   - YouTube demo video (< 3 min)

3. **Community**
   - Hacker News (Show HN)
   - r/LocalLLaMA (Ollama angle)
   - r/artificial (agent coordination angle)
   - AI Twitter/X (Ben's account + agent accounts)
   - Discord community

4. **Integrations**
   - OpenClaw plugin (first)
   - LangChain integration
   - CrewAI integration
   - AutoGPT integration
   - Each framework integration = distribution channel

5. **Word of Mouth**
   - Free tier is generous (10 agents, 50K msgs/day)
   - Self-host option means no risk to try
   - Each user who connects agents becomes an advocate

### Differentiators (What No One Else Has)

| Feature | RingForge | CrewAI | LangChain | AutoGPT |
|---------|-----------|--------|-----------|---------|
| Framework-agnostic | ✅ | ❌ | ❌ | ❌ |
| Local model workers | ✅ | ❌ | ❌ | ❌ |
| Task routing | ✅ | Manual | Manual | Manual |
| Self-hostable | ✅ | Partial | ❌ | ✅ |
| Real-time dashboard | ✅ | ❌ | LangSmith | ❌ |
| Shared memory | ✅ | ❌ | ❌ | ❌ |
| Presence system | ✅ | ❌ | ❌ | ❌ |
| Multi-tenant | ✅ | ❌ | ✅ | ❌ |

---

## Domain & Infrastructure Plan

| Asset | Current | Target |
|-------|---------|--------|
| Hub | ringforge.wejoona.com | hub.ringforge.io |
| Dashboard | ringforge.wejoona.com/dashboard | app.ringforge.io |
| Docs | — | docs.ringforge.io |
| Landing | — | ringforge.io |
| API | — | api.ringforge.io |
| GitHub | eshe-huli/ringforge (private) | ringforge/ringforge (org, public) |
| npm | — | @ringforge/sdk |
| PyPI | — | ringforge |

**Domain:** ringforge.io (check availability, budget ~$20-50)

---

## The Ollama Demo (The Hook)

This is the viral moment. The demo that sells RingForge:

```
1. Register on ringforge.io (10 seconds)
2. Pull two Ollama models on your laptop (2 minutes)
3. Run: npx ringforge-connect --key YOUR_KEY --ollama
4. Open dashboard → see both models as fleet agents
5. Submit a task: "Summarize this article"
6. Watch it route to Llama, get result in dashboard
7. Submit another: "Refactor this function"
8. Watch it route to Qwen (code capability)
```

**No code written. No framework. Local models doing real work through a global mesh.**

This is the Show HN demo. This is the tweet. This is the YouTube thumbnail.

---

## Risk Mitigation

| Risk | Mitigation |
|------|------------|
| Ben's time (4 jobs) | Onyx + Argus handle 90% of dev. Ben = strategy + content + face |
| Agent market too early | Free tier + self-host = low cost to wait. Build audience now |
| Big player builds this | Speed. Ship before they notice. Open source = community moat |
| No one connects | Ollama bridge = zero-dependency demo. No external agent needed |
| Scaling issues | Single VPS handles 500 agents. Scale problems = good problems |
| Security incident | Ed25519 auth, tenant isolation, no shared state. Audit at Phase 23 |

---

## Weekly Rhythm

- **Monday:** Plan week's work, check metrics
- **Wednesday:** Ship something. Every week.
- **Friday:** Deploy, test, write content
- **Saturday:** Community engagement, feedback review
- **Sunday:** Rest (Jumu'ah prep, personal time)

---

## Decision Log for This Plan

1. **Open source the hub** — This is the adoption play. Revenue comes from cloud, not software.
2. **Ollama demo first** — It's the lowest-friction way to show value. No API keys, no cloud dependency.
3. **GitHub OAuth before Google** — Target audience is developers. GitHub is their identity.
4. **Invite codes before public launch** — Control quality of early users. Get real feedback before scale.
5. **ringforge.io domain** — Professional. Short. Memorable. Worth the investment.

---

*"MVP doesn't mean rushed. I AM the market."* — Ben Ouattara

*Updated: 2026-02-07*
