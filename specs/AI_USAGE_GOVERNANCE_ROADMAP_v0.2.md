# AI Usage Governance Roadmap: Agent And Token Cost Management

Version: 0.2
Status: Draft for CTO review
Audience: CTO, enterprise architects, platform engineers, SRE/operations, divisional AI application owners
Primary post-read action: approve or amend the control-plane architecture and reliability model, then authorize the two-week POC defined in Stage 1.

Changes from v0.1: added reliability and distributed-systems design (section 4), multi-region and multi-cloud topology (section 5), service level objectives (section 6), observability across the token path (section 7), and incident response (section 8). Resolved the v0.1 open decision on regional gateway topology into a recommendation. Stage tasks updated to carry the reliability work.

## 1. Problem Statement

TWG is deploying AI capability along two axes at once:

- Server-side application AI: hometown EKG GraphRAG, Nexus CRM AI features, Intrepid loan_engine AI components, and sit-cip, running on parallel AWS/Bedrock and Azure/Foundry tracks.
- Desktop agents: users on Windows workstations running standalone agents governed by nono (Windows native) and zt-infra.

Today there is no organization-wide answer to four questions:

1. How many tokens is each application, team, and user consuming, on which models, on which cloud?
2. Who can stop a runaway agent or misconfigured application before it produces a five-figure invoice?
3. How is AI spend charged back or shown back to divisions?
4. How do we know when an agent on a workstation is calling a model provider outside any governed path?

A fifth question follows directly from answering the first four, and this version of the document addresses it: **if a single gateway carries every AI request in the organization, what keeps that gateway from becoming the single point of failure for every AI feature we ship?**

## 2. The Architectural Decision

**Decision: build a standalone AI control plane. Do not embed metering or cost components into individual applications (hometown, Nexus, Intrepid, nono, sit-cip).**

Rationale:

- Embedded metering gives N implementations to maintain and re-test every time a model, price sheet, or provider changes. A gateway centralizes that churn in one place.
- Embedded metering can observe but cannot enforce. An application cannot be budget-capped by code it owns and can modify. Enforcement must sit in the request path, outside the application.
- This mirrors the argument already accepted for the semantic layer (see WHY_CUBE_SEMANTIC_LAYER): govern at a layer with official models, rather than letting every consumer re-implement governance.
- Native cloud tagging alone is insufficient. Bedrock application inference profiles provide cost attribution but have per-account profile caps, no management UI, and are silently bypassed by direct API calls. Azure-side token policies do not see AWS traffic. Neither sees desktop agents.

What applications DO carry is a convention, not a component:

- Every AI call includes attribution metadata: `app_id`, `user_id`, `tenant_id`, `feature_tag` (for example `crm.deal_summary`, `ekg.graphrag_context`).
- Every application receives its model access through a gateway-issued virtual key, never a raw provider key.

This is a header-passing contract, comparable in weight to the existing semantic record contract, and it is the entire per-application burden.

## 3. Target Architecture: Three Tiers

### Tier 1: Gateway (Enforcement)

A self-hosted, OpenAI-compatible AI gateway fronts all model providers on both clouds.

Primary candidate: LiteLLM Proxy (open source, MIT).

- Unified interface to 100+ providers including Bedrock and Azure/Foundry; clients speak OpenAI format regardless of backend.
- Virtual keys per application, team, and user, with budgets, token rate limits, and model allowlists per key.
- Spend tracking with real-time model pricing lookup; usage persisted to Postgres.
- Fallback and load-balancing across providers (the AWS/Azure pilot tracks become swappable behind one endpoint).
- Enterprise tier (evaluate in Stage 2, not required for POC) adds Entra ID SSO, JWT auth, audit log retention, and the Prometheus metrics endpoint. Note for section 7: the Prometheus endpoint is enterprise-gated; the OSS observability path is callback-based (OpenTelemetry and compatible sinks).

Secondary/complementary candidates to record in the decision record:

- Azure API Management AI Gateway: native `llm-token-limit` and `llm-emit-token-metric` policies, unified model API (preview) that can front Bedrock as well as Foundry. Strongest if the organization later consolidates on Azure as the management plane.
- Bedrock application inference profiles: keep using them for AWS-side cost allocation tags under the gateway; complementary, not competing.

Operational requirements for whichever gateway is chosen:

- The gateway holds all raw provider credentials; treat it as Tier-0 secret infrastructure.
- Pin container images to specific versions and rotate credentials on deployment (note the March 2026 LiteLLM supply-chain disclosure; version pinning and credential rotation are the mitigations).
- The gateway request path must be horizontally scalable and stateless per request; all shared state (keys, budgets, rate counters, ledger) lives in Postgres and Redis, not in gateway process memory. See section 4.

### Tier 2: Endpoint Coverage (Desktop Agents)

Desktop agents flow through the same gateway, with nono acting as the compliance sensor rather than a metering component.

- Distribution: Intune/GPO pushes `ANTHROPIC_BASE_URL` / OpenAI-compatible base-URL environment configuration to managed Windows workstations, pointing agent tooling at the gateway.
- Identity: per-user virtual keys mapped to Entra ID identities, so desktop token consumption is attributable to a person, not a shared key.
- Enforcement backstop: nono's user-mode WFP layer already observes outbound network flows on the endpoint. A policy profile flags (POC) or blocks (MVP) direct connections from agent processes to known model-provider endpoints that bypass the gateway. This makes nono the detector for shadow AI usage without turning it into a billing system. nono detection events are also an observability input: see section 7.
- zt-infra agents adopt the same base-URL and virtual-key convention; no code component is added to zt-infra itself.

### Tier 3: Semantic Reporting (hometown)

Token usage is a business domain like loans and customers. It gets a governed Cube model, not a separate BI product.

- The gateway's usage ledger lands in Postgres (locally, the existing shared Docker Postgres instance; in the MVP topology, per-region ledgers consolidated into a reporting store — see section 5).
- Cube model: `ai_token_usage` with dimensions `app_id`, `team`, `user_id`, `model`, `provider`, `cloud`, `feature_tag`, `tenant_id`, time, and measures for tokens, USD cost, request count, and duration.
- Chargeback/showback, budget-vs-actual, and model-mix queries become governed semantic queries, consistent with the EKG's existing vocabulary and CI validation gate.
- The reporting path is explicitly NOT in the request path. Cube being down never blocks an AI request; the ledger being briefly stale never blocks an AI request. See the consistency model in section 4.

## 3A. Scope Boundary With The Ecosystem

Popeye owns the governed AI request path: gateway infrastructure, virtual keys, budgets, provider routing, request-path observability, the spend ledger, endpoint coverage policy, and break-glass controls. Hometown owns semantic interpretation: Cube models, trace/provenance contracts, GraphRAG behavior, governed access semantics, and business authorization. The shared contract is intentionally small: gateway `request_id` plus attribution metadata (`app_id`, `user_id`, `tenant_id`, `feature_tag`).

Program-level POCs that use the ledger or request IDs do not automatically become Popeye work. Answer provenance, governed access, evaluation harnesses, and federation designs remain outside this repository unless they require a change to the gateway contract, endpoint policy, or ledger delivery path.

## 4. Reliability And Distributed-Systems Design

### 4.1 Failure Domains And Blast Radius

The control plane introduces exactly one new failure domain into the AI request path: the gateway tier. Everything else is either already in the path (the model providers) or deliberately out of it (the ledger reporting path, Cube, dashboards).

Failure domain inventory, ordered by blast radius:

1. **Gateway request path down**: all governed AI traffic in the affected region stops. This is the domain that justifies the HA design below and the break-glass procedure in section 8.
2. **Model provider or specific model down**: requests to that backend fail; fallback routing absorbs it (4.4). Blast radius is a model, not the platform.
3. **Redis (rate/budget counter cache) down**: enforcement degrades, requests continue. Bounded-overspend consistency model applies (4.3).
4. **Ledger Postgres down**: enforcement based on cached counters continues; new spend records queue or drop depending on configuration. Reporting goes stale. Never blocks requests; ledger completeness reconciliation (7.4) quantifies any loss afterward.
5. **Cube / reporting tier down**: dashboards unavailable. Zero request-path impact.

Design rule: a component may only block requests if its job is enforcement. Observation and reporting components must never be able to block a request.

### 4.2 Availability Model

- POC (Stage 1): single gateway instance, single shared Postgres. Explicitly not HA. The POC measures baselines (section 6); it does not promise availability.
- MVP (Stage 2+): N stateless gateway replicas per region behind a load balancer. Replica count is a capacity decision, not a correctness decision, because per-request state never lives in a replica.
- Shared state services: managed Postgres (keys, budgets, ledger) and managed Redis (rate counters, router cooldown state, optional caching) per region, each with the cloud provider's standard HA options (multi-AZ, automated failover).
- The gateway database and the application-domain databases (Intrepid, CRM) must not share a failure domain in the MVP. The POC's use of the shared local Postgres is a POC-only convenience and is called out as such.
- Deployment is source-controlled infrastructure (Terraform modules exist for the primary candidate) with pinned image versions; upgrades are rolling, one replica at a time, with the previous version retained for immediate rollback.

### 4.3 Consistency Model

Be explicit with the CTO about what is strongly consistent and what is not, because budget enforcement across distributed replicas cannot be both perfectly accurate and non-blocking:

- **Virtual key validity and model allowlists: strongly consistent enough in practice.** Key checks hit the shared store; revocation propagates within seconds. Requirement: key revocation takes effect in under 60 seconds across all replicas (verify actual propagation during POC).
- **Budget and rate counters: eventually consistent with bounded overspend.** Spend is computed post-response and written asynchronously; concurrent requests across replicas can each pass a budget check before either's spend lands. The design invariant is therefore not "zero overspend" but "overspend bounded by (in-flight concurrency x max single-request cost) plus the counter update lag." Per-key max-token and max-budget settings cap the single-request term. The POC measures the actual lag; the MVP sets the bound as an SLO (section 6).
- **The ledger: append-only, eventually complete.** Reporting queries tolerate staleness; the freshness target is an SLO, not a request-path constraint.
- **Failure semantics per state store**: Redis unavailable means rate limiting degrades toward permissive (requests flow, enforcement weakens) — acceptable for minutes, alarmed immediately. Postgres unavailable means no new key issuance or budget updates; existing traffic continues on cached authorization for a bounded window.

This is the same trade the payments industry makes with authorization holds versus settlement, and it is the correct trade here: blocking every AI request in the organization behind a synchronous distributed budget transaction would buy exactness nobody needs at an availability cost everybody pays.

### 4.4 Provider Reliability (AI Reliability Proper)

The gateway is also the organization's answer to model-provider unreliability, which is a real and recurring operational fact, not an edge case:

- **Fallback chains**: each public model name (`twg-claude`, `twg-foundry`) declares an ordered fallback list. Primary use: absorb provider rate limits (429s) and outages. Cross-cloud fallback (Bedrock model falls back to Foundry model or vice versa) is configured deliberately per model group, never implicitly, because output behavior differs between models and some workloads must not silently switch.
- **Context-window fallbacks**: oversized prompts route to a larger-context model instead of erroring, configured per model group.
- **Timeouts and retries**: per-backend request timeouts; retries with exponential backoff and a hard retry budget. Critical interaction: retries consume tokens and money. Retry policy must count retried attempts against the caller's budget and must never retry non-idempotent tool-execution calls. Streaming responses that fail mid-stream are not silently retried; the error is surfaced to the caller, which must treat generation as at-most-once.
- **Health checking and cooldown**: backends failing repeatedly are cooled down and traffic shifts to fallbacks; recovery is automatic on health-check success.
- **Error taxonomy (mandatory)**: a caller must be able to distinguish, from the response, at minimum: (a) provider rate limit or outage (retryable, not the caller's fault), (b) budget exhaustion (not retryable, governance-intended, includes which budget and reset time), (c) policy rejection such as model not on allowlist (not retryable, actionable), (d) gateway internal error. Both budget exhaustion and provider throttling surface as 429s by default; the gateway must disambiguate them in the response body and headers. This taxonomy is what makes the fail-closed budget stance operable rather than a support burden.
- **Degraded modes, in order of preference**: serve from cache where semantically valid; fall back within the same cloud; fall back cross-cloud where the model group allows it; queue or shed with clear errors. Which features are allowed to degrade to a cheaper/smaller model is an application-owner decision recorded per feature tag, not a platform default.

### 4.5 Fail-Closed Versus Fail-Open, Stated Precisely

v0.1 said "budget enforcement fails closed for applications." That stands, but the full matrix is:

- Budget exhausted, gateway healthy: **fail closed** for applications (429 with budget error class); **fail visible** for interactive desktop users during pilot (alert plus block message, never a silent hang).
- Gateway tier down: this is not a budget event and "fail closed" is not an acceptable steady state for the whole organization's AI capability. Response is the break-glass procedure (section 8.3): time-boxed, logged, dual-approved direct provider access with retroactive attribution. Break-glass exists so that the honest answer to "what if your gateway dies" is a procedure, not a shrug.
- Enforcement state (Redis) down, gateway up: fail open on rate limits for a bounded window with immediate alarm; budgets enforce against last-known counters.

## 5. Multi-Region And Multi-Cloud Topology

v0.1 left the one-gateway-versus-two question open. Recommendation, now that reliability requirements are explicit:

**Regional gateway per cloud. `gateway-aws` fronts Bedrock from AWS; `gateway-azure` fronts Foundry from Azure. Same software, same configuration conventions, separate failure domains.**

- **Routing rule**: workloads call the gateway co-located with their compute. AWS-hosted application components call `gateway-aws`; Azure-hosted components call `gateway-azure`; desktop agents route via a stable DNS name (`ai-gateway.twg.internal`) that resolves to the designated primary for endpoint traffic, with documented failover.
- **Why not one gateway fronting both clouds**: a single gateway adds a mandatory cross-cloud network hop to one pilot track's every request (latency and egress cost), couples both clouds to one failure domain, and makes the AWS-versus-Azure pilot comparison unfair by taxing one side. Regional gateways keep the pilot honest.
- **Cross-region behavior on gateway failure**: clients retry against the other region's gateway only for model groups explicitly marked cross-cloud-safe. This is configuration, not improvisation, and the same list drives cross-cloud fallback in 4.4.
- **Ledger topology**: each regional gateway writes to its regional ledger (write-local, never cross-cloud in the request path). A consolidation job replicates both regional ledgers into one reporting store on a schedule; the `ai_token_usage` Cube model reads the consolidated store and carries a `cloud` dimension natively. Consolidation lag is covered by the ledger-freshness SLO. Regional ledgers are the source of truth; the reporting store is a derived view and can be rebuilt.
- **Consistency across regions**: budgets are enforced regionally against a global allocation split per region (simple, availability-friendly). A globally synchronous budget across clouds is explicitly rejected for the same reason as 4.3. If a division needs one budget spanning both clouds, allocate portions per region and rebalance from consolidated reporting.
- **Data residency**: the ledger carries token counts, costs, and attribution only — no prompt or completion content (guardrail, section 9). This is what makes cross-region ledger consolidation a low-sensitivity data flow rather than a compliance project.
- **Sequencing**: the POC remains a single local instance; Stage 2 deploys `gateway-azure` OR `gateway-aws` (whichever pilot leads) as the first managed instance; Stage 3 adds the second region and consolidation.

## 6. Service Level Objectives

The POC's job is to measure baselines; the MVP's job is to commit to targets. Numbers below are provisional targets to be confirmed against POC measurements — bring them to the CTO as proposals, not promises.

SLIs, and provisional MVP SLOs:

- **Gateway availability** (successful non-4xx handling of well-formed requests at the gateway boundary, per region): 99.9% monthly. The gateway must not be meaningfully less available than the providers behind it.
- **Gateway added latency** (gateway-internal processing time, excluding provider time; measured because "the AI got slower" complaints will land on this project): p95 under 150 ms, p99 under 400 ms on non-streaming; time-to-first-token overhead under 200 ms p95 on streaming. POC task: measure with and without gateway to establish the true delta.
- **Request success rate** (excluding caller errors and budget-intended rejections): 99.5% including fallback absorption. Provider outages absorbed by fallback count as successes; that is the point of the fallback tier.
- **Budget enforcement correctness** (bounded overspend, per 4.3): overspend on any key in any month under 5% of that key's budget or under a fixed dollar floor, whichever is greater. POC task: measure counter-update lag under concurrent load to validate the bound is achievable.
- **Key revocation propagation**: under 60 seconds from admin action to enforcement on all replicas.
- **Ledger freshness** (request completion to row queryable through Cube in the reporting store): under 15 minutes p95 in MVP (covers regional write plus consolidation). POC measures single-instance freshness, expected to be near-immediate.
- **Attribution completeness** (share of ledger rows carrying app_id and user_id; feature_tag tracked separately as an adoption metric): 99% for app_id/user_id — enforced structurally by key issuance, so a miss indicates a key hygiene defect.
- **Bypass detection coverage** (nono-managed endpoints reporting policy status; detection-to-alert latency for direct provider connections): coverage target set at Stage 3 rollout; detection-to-alert under 5 minutes.

Error budget policy: each SLO carries a monthly error budget; exhausting the gateway availability or latency budget freezes gateway feature changes (new policies, model onboarding) in favor of reliability work until the budget recovers. This is the standard SRE trade and should be stated up front so the first bad month has a pre-agreed consequence.

## 7. Observability Across The Token Path

### 7.1 The Token Path, End To End

Every request traverses: **caller → gateway (authn, policy, budget check) → provider (Bedrock or Foundry) → gateway (usage computation) → ledger write → consolidation → Cube (`ai_token_usage`)**. Observability is designed per hop, correlated by one identifier.

- **Correlation**: the gateway's `request_id` is the join key across access logs, traces, the ledger row, and any application-side logging. Applications should log the gateway request id they receive; that single convention makes "where did this request's tokens go" a lookup instead of an investigation.
- **Traces**: OpenTelemetry spans from the gateway (per-request: auth, policy evaluation, provider call, fallback attempts) following the OTel GenAI semantic conventions where applicable. Applications that already emit OTel propagate context into the gateway call so a GraphRAG request shows as one trace from Cube context fetch through model response.
- **Metrics**: request rate, error rate by error class (the 4.4 taxonomy), gateway-internal latency, provider latency, fallback activation rate, cache hit rate, tokens and cost per app/model/cloud, counter-update lag, ledger write failures. Honest procurement note: the primary candidate's native Prometheus endpoint is enterprise-gated; the OSS path is OTel/callback-based export into the existing monitoring stack, or derive cost metrics from the ledger itself. This is a concrete input to the Stage 2 OSS-versus-Enterprise ADR, not a footnote.
- **Logs**: gateway access logs with attribution dimensions and error class; admin audit events (key issuance, budget changes, config changes) logged and retained — configuration changes to the control plane are themselves part of the token path's audit story.

### 7.2 What Each Audience Watches

- **Operations**: availability, latency, error-class rates, fallback activations, state-store health. Paged on SLO-threatening burn rates, not on individual errors.
- **FinOps / division owners**: spend versus budget by app/team/cloud through the `ai_token_usage` Cube model; anomaly alerts on spend velocity (a key spending at a rate that exhausts its monthly budget in days).
- **Security**: nono bypass detections, key-usage anomalies (a desktop key suddenly calling from a server IP range, per-key request-origin drift), admin audit trail. nono events flow into the same alerting fabric — sit-cip is the natural consumer.

### 7.3 Alerting Baseline

Page: gateway availability burn, ledger write failures sustained beyond the freshness SLO, Redis/Postgres state-store failover events, error-class (d) internal errors above threshold. Notify (Teams, O365-native): budget thresholds at 50/80/100%, spend-velocity anomalies, fallback activation sustained beyond N minutes (a provider is degraded), nono bypass detections, attribution completeness dips.

### 7.4 Ledger Completeness Reconciliation

Because enforcement continues when the ledger is impaired (4.1), the ledger can silently under-count. Counter that structurally: a scheduled reconciliation compares gateway request counts (metrics path) against ledger row counts (data path) per hour per region, and separately spot-checks gateway-computed cost against the cloud bill (Bedrock cost-allocation tags, Azure cost views) monthly. Divergence beyond tolerance is a notify-level alert. Without this, "the dashboard says we spent X" is faith; with it, it is a verified claim — the same posture the EKG takes on schema contracts.

## 8. Incident Response

### 8.1 Severity Matrix

- **SEV-1**: gateway request path down in a region, or provider-credential compromise suspected. All-hands for the platform team; break-glass authorized.
- **SEV-2**: sustained provider outage exceeding fallback capacity; budget-enforcement malfunction blocking legitimate traffic; state-store failover with degraded enforcement.
- **SEV-3**: ledger freshness or completeness SLO breach; single-application key issues; sustained fallback activation with providers still serving.
- **SEV-4**: reporting/dashboard issues; attribution completeness dips.

### 8.2 Runbooks Required Before MVP (Stage 2 Exit Criteria)

1. **Gateway region outage**: verify LB and replica health; roll back last deployment if correlated; fail cross-cloud-safe model groups to the peer region; invoke break-glass if restoration exceeds the availability error budget's tolerance.
2. **Provider/model outage**: confirm fallback absorption; if fallback capacity is exceeded, shed lowest-priority feature tags first (priority list maintained with application owners); communicate expected behavior changes when cross-model fallback activates.
3. **Mass budget-block event** (misconfigured budget or price-map error blocking many keys): distinguish intended enforcement from malfunction via the error taxonomy; emergency budget raise is an audited admin action with a documented approver, not a config edit.
4. **Key compromise**: revoke the virtual key (propagation SLO applies); review its ledger trail for exfiltration-shaped usage; if the master key or provider credentials are implicated, escalate to SEV-1 and rotate provider credentials. Standing caveat, learned from the tooling itself: the salt key encrypting stored credentials must never be rotated casually — rotating it invalidates stored provider credentials. Document this in the runbook so nobody discovers it during an incident.
5. **Ledger/state-store outage**: confirm request path continuity; quantify enforcement degradation window; run the 7.4 reconciliation after recovery to bound data loss and file the delta with FinOps.
6. **Upstream supply-chain advisory** (the gateway is Tier-0 and self-hosted): pinned-version posture means "are we on an affected version" is answerable in minutes; procedure is assess, hotfix to patched pin, rotate credentials, review admin audit log for the exposure window. The March 2026 incident is the template.

### 8.3 Break-Glass Procedure

Purpose: bound the worst case of centralizing the token path. When the gateway cannot serve and restoration will exceed tolerance, named approvers (two-person rule) may issue time-boxed direct provider credentials to specific critical applications. Conditions: expiry enforced (hours, not days), scope limited to named apps, usage retroactively attributed into the ledger from provider-side logs and billing tags, and a post-incident review is mandatory including confirmation that break-glass credentials were destroyed. Desktop agents are never in break-glass scope; degraded desktop AI is an acceptable incident cost, uncontrolled desktop egress is not (and would fight nono's own policy).

### 8.4 Ownership

The control plane needs a named operational owner before Stage 2 exit — a platform team with on-call, not a side responsibility of an application team. The POC does not need on-call; the MVP absolutely does, and the CTO conversation should surface this staffing implication explicitly rather than letting it arrive as a surprise in Stage 3.

## 9. Guardrails

- The gateway must never log full prompt/completion bodies into the shared usage ledger; token counts, costs, and attribution dimensions only. This preserves the existing STATE guardrail against emitting sensitive payloads, and it is also what keeps cross-region ledger consolidation low-sensitivity (section 5).
- No raw provider API keys in application configuration, source control, or workstation environment variables; virtual keys only. Break-glass (8.3) is the sole, audited exception.
- Budget enforcement actions must be distinguishable from provider throttling in the response (error taxonomy, 4.4); fail closed for applications, fail visible for interactive desktop users during the pilot.
- Tenant-scoped applications (Intrepid) must include `tenant_id` in attribution so per-tenant AI cost is separable from day one.
- Observation and reporting components must never be able to block a request (design rule, 4.1).
- Retries must count against caller budgets and must never be applied to non-idempotent tool-execution calls (4.4).
- Gateway-level content guardrail/DLP evaluation is in MVP scope, but prompt and completion bodies must not be persisted in the spend ledger. Any PII masking or prompt-injection screening must be measured for latency and failure-mode impact before enforcement is enabled.

## 10. Roadmap Stages

### Stage 1: Control-Plane POC (target: 2 weeks)

Goal: prove enforcement, attribution, and semantic reporting end to end with one application path and one desktop path, and capture the reliability baselines that section 6 SLOs will be set against.

Tasks:

1. Deploy LiteLLM Proxy in Docker alongside the existing shared local Postgres; pin the image version.
2. Configure two backends: one Bedrock model and one Foundry model, behind one OpenAI-compatible endpoint, with a fallback chain between them for one model group.
3. Issue three virtual keys: `hometown-ekg` (app), `intrepid-ai` (app), and one per-user desktop key.
4. Route one hometown GraphRAG-style completion call through the gateway with attribution headers.
5. Point one desktop agent instance at the gateway via base-URL environment configuration; confirm per-user attribution.
6. Set a deliberately low budget on one key and demonstrate hard enforcement (429 on breach), confirming the budget-versus-throttle error distinction from the caller's view.
7. Land usage in Postgres; build and validate the `ai_token_usage` Cube model; run one chargeback query per app and per user through Cube.
8. Configure a nono policy profile that logs direct-to-provider connections from an agent process bypassing the gateway; demonstrate one detection.
9. Reliability baselines: measure gateway added latency (with/without-gateway delta, p50/p95/p99, streaming TTFT overhead); measure budget counter-update lag under concurrent requests; simulate a provider failure and record fallback behavior; kill the ledger connection mid-traffic and confirm requests continue, then run a first manual request-count-versus-ledger reconciliation.
10. Wire OTel/callback export from the gateway into the existing monitoring stack for one dashboard: requests, errors by class, tokens, cost.

Exit criteria:

- One query answers: tokens and dollars by application, user, model, and cloud for the pilot window.
- One demonstrated budget enforcement event, distinguishable from provider throttling.
- One demonstrated bypass detection event via nono.
- One demonstrated provider-failure fallback event.
- A measured baseline document: latency overhead, counter lag, ledger freshness — the inputs that turn section 6's provisional targets into committed SLOs.
- No raw provider keys present in any application or workstation configuration.

### Stage 2: First Managed Region, Policy Hardening, And Operational Readiness

- Deploy the first managed regional gateway (cloud chosen by pilot priority) as source-controlled infrastructure: N replicas, managed Postgres and Redis, pinned releases, secret-store-backed credentials, rolling upgrades with rollback.
- Onboard Nexus CRM AI and sit-cip with their own virtual keys and feature tags; define the budget hierarchy (org, division, application, user) and model allowlists per application.
- Commit MVP SLOs from Stage 1 baselines; stand up the alerting baseline (7.3) and the ledger reconciliation job (7.4).
- Write and rehearse the six runbooks (8.2), including one game-day exercise of the break-glass procedure.
- Name the operational owner and on-call arrangement (8.4).
- Decide LiteLLM OSS vs. Enterprise vs. Azure APIM as the long-term gateway; the Prometheus gating, SSO, audit-retention, and gateway hook/guardrail needs from sections 7-9 are explicit ADR inputs.
- Evaluate gateway-level content guardrails and DLP on the hook surface: PII masking, prompt-injection screening, latency/error impact, and whether the controls can run without storing prompt or completion bodies in the spend ledger.

### Stage 3: Second Region And Fleet Rollout

- Deploy the second regional gateway; establish ledger consolidation into the reporting store; re-point Cube at the consolidated store; confirm ledger-freshness SLO across consolidation.
- Define and configure the cross-cloud-safe model group list with application owners; test cross-region failover.
- Intune/GPO rollout of gateway base-URL configuration and per-user key provisioning tied to Entra ID.
- nono policy moves from flag to block for unauthorized direct provider traffic, with an exception process; bypass-detection coverage SLI activated.
- zt-infra agent identities integrated into the same key/attribution scheme.

### Stage 4: FinOps Operationalization

- Monthly showback reports per division from the `ai_token_usage` Cube model, backed by the monthly bill-versus-ledger spot check (7.4).
- Budget alerts to Teams at 50/80/100% thresholds; spend-velocity anomaly detection.
- Semantic caching evaluation at the gateway for high-repetition workloads (measured, not assumed); cache hits visible in the ledger at zero provider cost.
- Pre-aggregations on the usage model for dashboard latency, consistent with Stage 1 Cube roadmap work.

## 11. Open Decisions

- Gateway product decision: LiteLLM OSS vs. LiteLLM Enterprise vs. Azure APIM AI Gateway as the long-term standard (Stage 2 ADR; observability gating, SSO, audit retention, and content guardrail/DLP hook support are named inputs).
- ~~One gateway vs. regional gateways~~ — resolved in v0.2: regional gateway per cloud (section 5), pending CTO confirmation.
- Which model groups are cross-cloud-safe for fallback and failover (application-owner decision per feature tag; needed by Stage 3).
- Whether desktop enforcement (nono block mode) requires legal/HR review before moving beyond flag mode.
- Consolidated reporting store placement (which cloud hosts it) and consolidation mechanism (logical replication vs. scheduled ETL) — Stage 3 decision; low sensitivity given the no-content guardrail.
- Break-glass approver list and expiry defaults (named individuals; needed before Stage 2 exit).
- Operational ownership: which team carries on-call for the control plane (8.4; a staffing decision, flagged for the CTO conversation).
- LLM provider decision for hometown itself (currently open in STATE.md) — the gateway makes this decision reversible, which is an argument for deploying the gateway first.

## 12. Summary For The CTO

One standalone control plane, three tiers: a gateway that enforces budgets and issues keys, endpoint configuration plus nono as the bypass detector for desktop agents, and a Cube semantic model that makes AI spend a first-class queryable business domain in the Enterprise Knowledge Graph. Applications contribute attribution headers and nothing else.

The reliability posture, stated plainly: the gateway is the one new failure domain we introduce, so it runs as stateless replicas per cloud region with no cross-cloud hop in any request path; budget enforcement trades perfect accuracy for availability with a measured, bounded overspend; reporting can never block a request; provider outages are absorbed by explicit fallback chains; and the worst case — a gateway region down — has a rehearsed, time-boxed, dual-approved break-glass procedure rather than an improvised one. The POC is two weeks, runs on infrastructure we already operate locally, and now exits with measured latency, consistency, and freshness baselines so the SLOs we commit to in the MVP are numbers we observed, not numbers we hoped.
