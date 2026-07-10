# Popeye Stage 1 POC: Kickoff Direction

Version: 0.1
Status: Ready for team kickoff
Audience: POC execution team, hometown owner, nono owner, CTO (demo section)
Primary post-read action: fill in the five named assignments in section 2 and the two model selections in section 4, then start Stage 1 task 1.

Project codename: **Popeye**. Covers the AI usage governance control plane end to end: gateway, endpoint coverage, semantic reporting. Spec filenames keep their functional names; the codename is the program identity.

This document exists because the roadmap (v0.2) defines Stage 1's tasks and exit criteria but not its execution mechanics. The gaps closed here: naming (with one irreversible deadline), ownership, prerequisites and spend authorization, the measurement protocol that makes baselines reproducible, POC data rules, the demo script, and descope rules.

## 1. Naming: One Decision With A Deadline

Adopting the codename is free everywhere except Terraform. The `envs/azure-eastus2` root uses a `name_prefix` local (`aigw-...`) that lands in Azure resource names. Renaming resources after the first apply means destroy-and-recreate.

Direction: change the prefix to `popeye-` in `envs/azure-eastus2/main.tf` **before** the first Stage 2 apply, and rename the repo `popeye-infra`. Decision cost today: one line. Decision cost after apply: an outage. This is the only naming item with a deadline; everything else can drift in gradually.

## 2. Ownership (Fill In At Kickoff)

Five named assignments; a name per line, not a team per line:

- **POC lead**: owns the two-week timebox, the baseline document, and the descope calls in section 7. Single person.
- **hometown owner**: lands `ai_token_usage.yml` and the Cube validation in the hometown repo; runs the chargeback query in the demo.
- **nono owner**: builds the bypass-detection policy profile (or invokes the section 7 fallback); demos the detection.
- **Cloud access owner**: procures the two non-production model endpoints (section 3) — the most common schedule risk, so it is a named responsibility, not a shared hope.
- **CTO demo date**: set at kickoff, day 10 of the timebox. A date on the calendar is what makes the timebox real.

FinOps is an invited observer at the demo, not a POC role.

## 3. Prerequisites Checklist (Complete Before Task 1)

- Non-production AWS account with Bedrock model access enabled for the selected model (console action; not instant — request on day 1).
- Non-production Azure subscription with a Foundry deployment for the selected model, and its endpoint/key or RBAC path.
- **POC spend authorization: USD 50 hard cap, approved by name at kickoff.** The POC spends real tokens; the cap is enforced as a gateway-level budget on day 1, making Popeye's first governed budget Popeye's own.
- Local environment per hometown's existing pattern: shared Docker Postgres up, `deploy_default` network present, `cube/.env` populated from the example.
- Pinned LiteLLM `-stable` tag chosen and recorded (current supported lines at time of writing: 1.86–1.89; verify at kickoff).
- One managed Windows workstation with nono installed, and a desktop agent capable of honoring `ANTHROPIC_BASE_URL`.
- Master key generated at kickoff, held by the POC lead, stored in the local `.env` only. It is a POC secret, not a shared credential; it dies with the POC environment.

## 4. Model Pair Selection (Decide At Kickoff)

Pick one Bedrock model and one Foundry model of the **same capability class** — the latency and cost baselines feed the AWS-versus-Azure pilot comparison, and mismatched classes poison that data. Record both choices and their list prices in the baseline document header. If the same model family is available on both (e.g., a Claude-class model via Bedrock and a comparable-class Foundry deployment), prefer that for the cleanest comparison.

## 5. Measurement Protocol (Makes Task 9 Reproducible)

Baselines that cannot be reproduced are anecdotes. Protocol for each measurement, all run from the same host as the gateway container to exclude workstation network noise:

- **Latency overhead**: 100 non-streaming completions with a fixed synthetic prompt (~200 tokens in, `max_tokens` 256) direct-to-provider, then the same 100 through the gateway to the same backend. Report p50/p95/p99 of the *difference distribution*, not of the two averages. Repeat once for streaming, reporting time-to-first-token deltas. Same for both backends.
- **Budget counter lag**: set a key's budget so ~5 requests exhaust it; fire 20 concurrent requests; record how many succeed past the budget line and the wall-clock spread between the last over-budget success and the first 429. That count and spread are the measured overspend bound (roadmap 4.3).
- **Ledger freshness**: timestamp request completion versus the row's queryability through Cube; 20 samples, report p95.
- **Fallback behavior**: point the primary backend at an invalid endpoint mid-run; record error classes surfaced (per the roadmap 4.4 taxonomy), fallback activation, and recovery on restoring the endpoint. Capture the actual 429 response bodies for budget-versus-throttle so the taxonomy claim is verified with real payloads, not documentation.
- **Ledger interruption**: stop the Postgres container for 60 seconds under a 1 req/s trickle; confirm requests continue; after restart, run the manual reconciliation (request count from gateway logs versus ledger rows) and record any loss.

Environment note recorded once in the baseline doc: this is single-instance local Docker; numbers are floors and ceilings for intuition, and Stage 2's managed deployment re-verifies before SLOs are committed (roadmap section 6).

## 6. POC Data Rules

- **Synthetic prompts only.** No real CRM records, loan data, tenant data, or personal data through the POC gateway — its container, config, and ledger are non-hardened local infrastructure. Use generated placeholder text; the tokens count the same.
- `store_prompts_in_spend_logs` stays false (already in the config); spot-check the ledger on day 1 to confirm no `messages`/`response` content lands (the columns exist and must stay empty).
- Non-production credentials only, local `.env` only, nothing committed — standing hometown guardrails apply unchanged.

## 7. Descope Rules (Decided Now, Not Under Pressure)

Two-week timebox, demo on day 10, days 11–12 for the baseline document. If blocked:

- **Must hold** (the demo is these four): budget enforcement event; chargeback query through Cube; one measured latency baseline; attribution end to end (app + user visible in the query).
- **May slip with a stand-in**: nono bypass detection. If the policy profile isn't demo-ready, an equivalent detection from nono's existing flow logging (or, worst case, Windows Firewall logging) demonstrates the *concept* with an honest caption; the productized policy moves to Stage 3 where it was already scheduled to mature.
- **May slip entirely**: the second cloud backend. If Foundry or Bedrock access stalls past day 5, run the POC single-provider and say so; the gateway's multi-provider claim is demonstrated by configuration, not blocked on procurement.
- **Kill criterion**: if by day 5 no model endpoint is reachable at all, stop, escalate the access problem to the CTO as the finding, and reschedule. An access-blocked POC that limps produces bad baselines and a worse demo.

## 8. CTO Demo Script (Day 10, ~15 Minutes)

Build toward this from day 1; every task output is a beat in it:

1. **One slide**: the three-tier architecture and the sentence "applications contribute attribution headers and nothing else."
2. **Live**: a completion through the gateway; the attributed ledger row; the same spend appearing in a Cube `ai_token_usage` query by app, user, model, cloud.
3. **Live**: the runaway-agent story — a low-budget key hits its cap, the 429 with the budget error class, visibly distinct from provider throttling.
4. **Live or captured**: nono flags a direct-to-provider bypass from a workstation.
5. **Captured**: fallback absorbing a dead backend.
6. **One slide**: measured baselines table, and the ask — approve Stage 2 (first managed region, the scaffolded `envs/azure-eastus2`), the operational-owner decision (roadmap 8.4), and the break-glass approver names (roadmap section 11).

The demo ends on the asks. The baselines make the SLO conversation concrete; the two open decisions (owner, approvers) are the ones only the CTO can close.

## 9. Baseline Document Template

`specs/STAGE1_BASELINES.md`, produced days 11–12, structure fixed now:

- Header: dates, gateway image tag, model pair and list prices, environment note (section 5).
- One section per measurement (latency, counter lag, freshness, fallback, ledger interruption): method reference, raw summary numbers, and the single sentence "therefore the provisional SLO of X is / is not achievable as written."
- Closing: proposed committed SLO numbers for roadmap v0.3, and any taxonomy or behavior surprises with the captured payloads.

This document is Stage 1's real deliverable. The demo persuades; the baselines commit.
