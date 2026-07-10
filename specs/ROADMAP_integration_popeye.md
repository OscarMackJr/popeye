# Popeye Roadmap

Status: Active
Version: 2026-07-10
Audience: popeye team - platform engineers, SRE/operations, cloud owners, and future implementation agents
Primary post-read action: know the current stage, its tasks and exit criteria, and exactly which ecosystem work belongs to this team and which does not.

## Purpose

Popeye is TWG's AI usage governance control plane: one gateway that every AI model request flows through, giving the organization budgets, virtual keys, attribution, provider failover, and a spend ledger - plus endpoint coverage (desktop agents via Intune configuration and nono detection) so the governed path is the only practical path.

This file is the team's working sequencing surface. The architecture, reliability model, SLOs, and incident-response design live in the governance roadmap spec and are not repeated here; this file says what to build next.

## The Boundary With hometown (Read This First)

popeye and hometown meet at exactly one join key and one vocabulary:

- This team's gateway writes the spend ledger; every request carries a `request_id`. hometown reads it (read-only, `ekg_cube_reader`) and owns all Cube models over it, including `ai_token_usage` and the Stage 4 trace join.
- Attribution vocabulary (`app_id`, `user_id`, `tenant_id`, `feature_tag` via `spend_logs_metadata`) is shared verbatim. Changing it is a two-team contract change, never a quiet edit.

popeye does NOT own: Cube models, the semantic record or trace contracts, GraphRAG, or any interpretation of what requests mean. The gateway is semantics-blind by design - it knows what requests cost, never what evidence means. If a task involves modeling, provenance, or authorization semantics, it belongs to hometown (their Stages 4 and 5).

hometown does NOT own: the gateway, virtual keys, budgets, provider credentials, the Terraform in this repository, ledger write paths, or nono/Intune endpoint policy.

## Scope And MVP

Popeye's product scope is the governed AI request path and the operating controls around it. The MVP is not just "a gateway deployed"; it is a deployable control plane that can enforce budgets, attribute usage, survive common provider failures, and provide the ledger that hometown turns into semantic reporting.

In scope for this repository:

- Regional gateway infrastructure, starting with Azure eastus2 and then AWS us-east-1.
- Gateway configuration: provider backends, fallback chains, model allowlists, virtual keys, budget policies, and no-prompt-logging guardrails.
- State stores for keys, budgets, counters, and the regional spend ledger.
- Request-path observability, error taxonomy, budget-versus-provider-throttle distinction, and ledger completeness reconciliation inputs.
- Endpoint coverage work owned by Popeye: Intune base URL rollout, per-user key provisioning, and nono bypass-detection/blocking policy integration.
- Break-glass infrastructure and runbook support for audited, time-boxed direct provider access during gateway outages.
- Content guardrail and DLP evaluation at the gateway hook surface: PII masking, prompt-injection screening, and measurement of latency/error impact. This is configuration and policy evaluation, not a new application architecture.

Out of scope for this repository:

- Cube models, semantic trace models, provenance semantics, GraphRAG behavior, and governed business authorization. Those remain hometown-owned.
- Program POCs A, B, C, and E except where they consume Popeye's ledger, request IDs, or cost data.
- A custom proxy implementation. The direction remains deploy and configure maintained gateway software.

MVP includes Stage 1 and Stage 2 together:

- A running Azure eastus2 managed gateway with two replicas, managed Postgres, Managed Redis, Key Vault-backed secrets, a remote Terraform state backend, and a pinned LiteLLM image.
- One configured Foundry backend and one smoke completion through the gateway that lands an attributed row in the regional ledger.
- Virtual key issuance for at least two application identities and one desktop identity, with app/user/tenant/feature attribution.
- Budget enforcement with captured caller-visible budget errors that are distinguishable from provider throttling.
- `ai_token_usage` read access for hometown and one chargeback/showback query over the pilot window.
- One nono bypass-detection event or documented stand-in per the kickoff descope rules.
- Baseline measurements for gateway latency overhead, budget counter lag, ledger freshness, fallback behavior, and ledger interruption.
- MVP SLO numbers committed from those measurements, placeholder alert criteria replaced, and the six operational runbooks rehearsed.
- Gateway-level content guardrail/DLP evaluation results recorded with a go/no-go recommendation for PII masking and prompt-injection screening in the managed request path.

## Source Documents

- [AI Usage Governance Roadmap v0.2](./AI_USAGE_GOVERNANCE_ROADMAP_v0.2.md) - architecture, reliability and distributed-systems design, multi-region topology, SLOs, observability, incident response. The why behind every task below.
- [Gateway Infrastructure And Implementation Plan v0.1](./GATEWAY_INFRASTRUCTURE_PLAN_v0.1.md) - language decisions, per-cloud resource inventories, repository layout.
- [Popeye Stage 1 Kickoff v0.1](./POPEYE_STAGE1_KICKOFF_v0.1.md) - POC execution mechanics: ownership, prerequisites, measurement protocol, data rules, descope rules, demo script.
- [STATE](../STATE.md) - current implementation state and resumption tasks.
- Ecosystem portfolio and gap analysis (program-level) - charters POCs A-E; only the items restated below are this team's tasks.

## Roadmap Stages

### Stage 1: Control-Plane POC (active; two-week timebox, CTO demo day 10)

Goal: prove enforcement, attribution, and semantic reporting end to end, locally, and produce the measured baselines that turn provisional SLOs into committed numbers.

Status: awaiting kickoff assignments (five names, model pair, spend cap approval - kickoff doc sections 2-4).

Tasks (kickoff doc governs execution detail):

1. Deploy the pinned gateway image locally per the POC compose profile; enforce the USD 50 POC budget as a gateway budget on day 1.
2. Configure Bedrock and Foundry backends behind one endpoint with one fallback chain.
3. Issue three virtual keys (two apps, one desktop user); route one hometown GraphRAG-style call and one desktop agent through the gateway with attribution.
4. Demonstrate budget enforcement (429, budget error class, distinguishable from provider throttling - capture real payloads).
5. Demonstrate one nono bypass detection (stand-in allowed per descope rules).
6. Run the measurement protocol: latency overhead (paired-difference percentiles), budget counter lag under concurrency, ledger freshness, fallback behavior, ledger-interruption continuity plus reconciliation.
7. Hand hometown the ledger access for their `ai_token_usage` model and chargeback demo query (their Stage 1 extension; our task is the grant, not the model).
8. Deliver `specs/STAGE1_BASELINES.md` (days 11-12) - the stage's real deliverable.

Exit criteria: the four must-hold demo beats (budget block, chargeback query, latency baseline, end-to-end attribution), the baseline document, and no raw provider keys anywhere in app or workstation configuration.

### Stage 2: First Managed Region - Azure (applied; running with minimal boot config)

Goal: gateway-azure in eastus2 as source-controlled, operated infrastructure with committed SLOs.

The Terraform is applied in the TWG Architecture POCs subscription. The gateway is running on Azure Container Apps with a minimal LiteLLM boot config. The remaining Stage 2 work is to wire the selected Foundry deployment, prove an attributed completion, and harden the operational controls from Stage 1 baselines.

Tasks:

1. Pre-apply: rename `name_prefix` to `popeye-` (irreversible after apply), settle the state backend, decide ADR-002 (config delivery: config-baked image vs mounted volume).
2. Apply the regional stack; smoke completion through `twg-foundry` lands one attributed ledger row.
3. Commit MVP SLOs from Stage 1 baselines; replace placeholder alert criteria with burn-rate rules; stand up the ledger reconciliation job.
4. Onboard Nexus CRM AI and sit-cip: virtual keys, feature tags, budget hierarchy, model allowlists; raw-key removal is each app's onboarding exit criterion.
5. Write and rehearse the six runbooks, including one break-glass game day.
6. Name the operational owner and on-call (a CTO decision to force, not to wait for).
7. Decide ADR-001 (LiteLLM OSS vs Enterprise vs Azure APIM) - observability gating, SSO, and audit retention are the inputs.
8. Work item folded in from the program gap analysis: evaluate content guardrails/DLP on the gateway hook surface (PII masking, prompt-injection screening). Configuration and measurement, not new architecture.

Exit criteria: region live on pinned releases with rollback, SLOs committed and alarmed, two apps onboarded keyless, runbooks rehearsed, owner named.

### Stage 3: Second Region, Reporting, Fleet Rollout

Goal: gateway-aws (us-east-1), consolidated reporting store, and desktop coverage at fleet scale.

Tasks:

1. Build `envs/aws-use1` starting from the vendor's registry module, forked under this repo's conventions; IAM task role to Bedrock, no long-lived keys; application inference profiles per app for cost-allocation tags.
2. Stand up the reporting store and ledger consolidation (placement and mechanism are ADR-003); re-point hometown's Cube at the consolidated store; verify the freshness SLO across consolidation.
3. Configure the cross-cloud-safe model group list with application owners (ADR-004); test cross-region failover.
4. Fleet rollout: Intune base-URL configuration, per-user key provisioning tied to Entra (scripts/ skeletons become real), nono policy from flag to block with an exception process.
5. Begin egress hardening (block direct provider egress from application subnets) - only after fallback and break-glass are rehearsed, because it converts gateway-down from degraded to hard-down.

### Stage 4: FinOps Operationalization

Goal: the governance loop becomes routine operations.

Tasks: monthly showback per division from `ai_token_usage` (hometown's model, our data); bill-versus-ledger monthly spot check via cloud cost-allocation tags; budget and spend-velocity alerts to Teams; semantic caching evaluation (measured, not assumed); support hometown's pre-aggregation work with query-pattern data.

## Program Work This Team Watches But Does Not Build

- POC A (answer provenance): hometown Stage 4. Our ledger is its join target; zero popeye changes.
- POC B (governed access): hometown Stage 5. Runs alongside our Stage 2 - both are Entra identity work, so coordinate sprint rhythm, not code.
- POC C (evaluation): consumes traces and our cost data; harness placement undecided.
- POC E (federation over zt-infra): design spec chartered at program level; if the envelope exchange becomes a deployable service, it earns its own repository - not this one.
- Shareability workstream (sister organizations): licensing, history hygiene, reference deployment. Starts on CTO confirmation; this repo's clean-clone story is already close and should stay that way.

## Sequencing Summary For The Team

Stage 1 starts the day the kickoff assignments are filled. Stage 2 applies only after the baselines exist and the pre-apply naming/backend/ADR-002 decisions are made - the Terraform waiting is not an invitation to apply early. Stage 3 waits for Stage 2's runbooks to be rehearsed, not merely written. Guardrails in STATE.md bind every stage.
