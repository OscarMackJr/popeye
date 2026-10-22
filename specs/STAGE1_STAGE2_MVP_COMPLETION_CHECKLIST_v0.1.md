# Stage 1 / Stage 2 MVP Completion Checklist

Version: 0.1  
Status: Active  
Audience: development, network administration, platform/DevOps, data, security, and POC owners  
Post-read action: each owner accepts the requests assigned below and records the required evidence.

## Objective

Close the current MVP slice by proving one governed completion travels through the Azure internal gateway and creates an attributed regional ledger row. The proof then becomes the starting point for Stage 1 baseline measurements and operational-readiness work.

This is not a request to expose the gateway publicly or to relax existing secret, no-prompt-logging, or least-privilege controls.

## Shared operating rules

- Use synthetic or otherwise approved non-sensitive test content only.
- Do not copy virtual keys, master keys, database passwords, or full prompts into tickets, chat, logs, or this document.
- Correlate evidence with a timestamp and request identifier; redact tokens and user-identifying values.
- Record an explicit skip reason, prerequisite, owner, and target date for any test that cannot run.
- Treat the Terraform state and read access to it as sensitive access.

## Workstream 0 — POC coordination

**Owner:** POC lead / platform owner

- [ ] Name one accountable owner for each workstream below.
- [ ] Create a single evidence location accessible to the POC reviewers.
- [ ] Schedule a short joint execution window for the smoke test: development, platform/DevOps, network, and data support should be reachable.
- [ ] Confirm the test application/team identifiers and feature tag to use for attribution.
- [ ] Record blockers and decisions in `STATE.md`; update the status after each completed gate.

**Evidence:** owner list, execution date, evidence location, and test attribution values.

## Workstream 1 — Internal network path and DNS

**Owner:** Network administration, with platform/DevOps support

### Request to network administration

- [ ] Decide the ownership model for `ai.twg.internal`: central networking owns the private DNS zone, or the Popeye stack is delegated the required zone/records.
- [ ] Provide the approved DNS record or delegation for `gateway-azure.ai.twg.internal` to the Azure Container App internal FQDN.
- [ ] Establish the required private routing and VNet peering between the approved caller network and the Container Apps environment.
- [ ] Confirm the approved source subnet(s) and DNS resolver path for the test workstation or jump host.
- [ ] Provide a named network owner and completion date. The current decision target is **2026-08-15**.

### Request to platform/DevOps

- [ ] Supply the current internal Container App FQDN to network administration through the approved operational channel.
- [ ] Verify that ingress remains internal-only after DNS and routing changes.
- [ ] From an approved caller network, verify DNS resolution, TLS reachability, and a health response without revealing credentials.

**Exit evidence:** timestamped DNS lookup and health/reachability result from an approved caller path, plus the documented DNS ownership decision.

## Workstream 2 — Governed gateway-to-ledger smoke proof

**Owners:** Development and platform/DevOps; data support validates the ledger

### Request to development

- [ ] Prepare a minimal OpenAI-compatible completion request using synthetic prompt content and the approved virtual key.
- [ ] Include the agreed attribution fields: application, team, user or service identity, feature tag, and request identifier.
- [ ] Send the request to `gateway-azure.ai.twg.internal` and the approved `twg-foundry` model.
- [ ] Capture a sanitized response record: UTC timestamp, HTTP status, model name, request identifier, and relevant response headers.
- [ ] Do not fall back to a direct provider endpoint; the request must traverse Popeye.

### Request to platform/DevOps

- [ ] Provide a secure execution path from an approved network location. Preferred options are an approved jump host or a managed interactive diagnostic session; do not place secrets in shell history or command output.
- [ ] Confirm both Container App replicas are healthy before the request.
- [ ] Collect gateway-side correlation evidence needed to connect the request identifier to the ledger write, while preserving no-prompt-logging behavior.
- [ ] If execution cannot proceed, record the precise limitation and a remediation owner rather than declaring the smoke test complete.

### Request to data / database support

- [ ] Confirm the designated read-only role can query the regional ledger without application credentials or Terraform-state access.
- [ ] Query for the smoke request using the timestamp and request identifier.
- [ ] Verify expected attribution fields, model/cloud identity, token/cost fields where available, and no prompt content.
- [ ] Save a sanitized query result or signed verification note in the evidence location.

**Exit evidence:** one sanitized gateway response and one matching attributed ledger row. This gate is not complete until both are present.

## Workstream 3 — Stage 1 baseline measurements

**Owners:** Development and platform/DevOps; POC lead approves results

- [ ] Create `specs/STAGE1_BASELINES.md` after the smoke proof succeeds.
- [ ] Measure gateway-added latency with paired direct-provider versus governed-request samples; report p50, p95, p99, and streaming time-to-first-token where applicable.
- [ ] Measure budget counter-update lag under concurrent requests.
- [ ] Measure ledger freshness and perform a basic request-count-versus-ledger reconciliation.
- [ ] Interrupt ledger connectivity during controlled traffic; confirm intended request-path behavior and record reconciliation outcome.
- [ ] Capture actual budget-exhaustion and provider-throttling responses so caller-visible taxonomy is evidenced rather than inferred.
- [ ] Record fallback as demonstrated with a second backend or explicitly skipped with the second-provider prerequisite, named owner, and target date.
- [ ] State whether each provisional SLO is achievable, unsupported, or needs revision.

**Exit evidence:** reviewed baseline document containing method, sample scope, results or explicit skip, and proposed MVP SLO values.

## Workstream 4 — Security and DLP/guardrail evaluation

**Owners:** Security/AI governance and development; platform/DevOps supports telemetry

### Request to security / AI governance

- [ ] Define synthetic test cases for PII masking, prompt-injection screening, and required content-policy checks.
- [ ] Specify acceptance thresholds for false positives, false negatives, added latency, and failure behavior.
- [ ] Confirm whether evaluation may use the gateway hook surface without retaining prompts; otherwise provide the approved test method.
- [ ] Issue an MVP go/no-go recommendation and list production-only controls.

### Request to development and platform/DevOps

- [ ] Run approved tests only with synthetic data.
- [ ] Measure latency and error impact, and verify no-prompt-logging remains effective.
- [ ] Document the recommended control point, implementation effort, operational ownership, and rollback behavior.

**Exit evidence:** documented go/no-go recommendation with test results, known limitations, and follow-up owner.

## Workstream 5 — Operational readiness and runbooks

**Owners:** Platform/DevOps, security, and POC lead

- [ ] Assign named break-glass approvers or an approved PIM/group model; replace the temporary signed-in-principal posture before MVP exit.
- [ ] Rehearse the six MVP runbooks: gateway failure, provider failure, ledger interruption, budget-enforcement issue, secret/salt-key incident, and break-glass access.
- [ ] Test conservative gateway and Postgres alerts under an approved controlled-failure condition; retain alert delivery evidence.
- [ ] Identify baseline-dependent alert classes and record their source data, owner, and threshold-decision date.
- [ ] Confirm Terraform no-change plan, GitHub Actions execution, and resource-health checks after operational changes.

**Exit evidence:** dated runbook notes, alert test results, approved approver model, and outstanding-risk list.

## Workstream 6 — Deferred dependencies and decisions

**Owner:** POC lead, with the relevant external owner

- [ ] **Private DNS:** record the `ai.twg.internal` ownership decision and execution outcome by 2026-08-15.
- [ ] **Second provider / fallback:** record whether Bedrock or another approved backend is available; if not, retain the explicit single-provider descope and name the Cloud access owner and target date.
- [ ] **Stage 3 automation:** retain Intune/Graph key-lifecycle work as a Stage 3 item; it is not a prerequisite for the Stage 2 smoke proof.
- [ ] **Hometown integration:** confirm the request-ID and attribution contract plus read access for the chargeback query; Popeye owns the ledger path, hometown owns the Cube model.

## Completion decision

The current MVP slice can be proposed for closure only when all items below are checked:

- [ ] Internal DNS/routing makes the gateway reachable from an approved caller path.
- [ ] A governed smoke completion has a matching, attributed ledger row.
- [ ] `specs/STAGE1_BASELINES.md` contains required measurements, results or formal skips, and proposed MVP SLOs.
- [ ] DLP/guardrail evaluation has a documented go/no-go recommendation.
- [ ] Runbooks, break-glass approvers, alert evidence, and operational owners are documented and rehearsed.
- [ ] Any remaining dependency is explicitly descoped with an owner, date, and risk statement.
