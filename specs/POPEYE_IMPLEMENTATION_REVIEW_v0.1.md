# Popeye Implementation Review

Version: 0.1
Status: Draft — review of `OscarMackJr/popeye`, branch `main`
Audience: CTO, popeye team, POC lead
Primary post-read action: fix P1 through P4 before the POC. P2 and P3 concern infrastructure that is already live and carrying traffic.
Basis: source inspection against the popeye specification set. No Terraform was run; no plan was generated.

## 1. Summary

The Terraform is the most disciplined code in the program. Structural guardrails from the specifications are genuinely encoded — the image tag validation rejects `latest`, `min_replicas` refuses anything under two, the salt key carries `prevent_destroy` with ignored value drift, the ledger database is protected and network-isolated, and the break-glass vault is properly dormant. The `.gitignore` is correct and effective, the provider lock file is committed, and the state backend uses Entra authentication. The no-prompt-logging guardrail appears in the *rendered* configuration, not merely in the example — which is the version that matters.

The findings are of a different character than hometown's. Nothing here is wrong in the way a mis-typed column is wrong. What is missing is the operational layer around infrastructure that is **already applied and live**: there is no CI, the single alert that exists cannot fire, the container has no health probes, and the regulated-data enforcement that C2 identified as the program's highest-stakes gap has no implementation on this side at all.

Recommendation: P1 through P4 before the POC. P2 and P3 are the ones I would not leave running over a weekend.

## 2. What Is Well Built

**The validation blocks work as intended.** Two constraints that specifications usually express as prose are here expressed as `terraform plan` failures:

```hcl
condition     = var.litellm_image_tag != "latest" && var.litellm_image_tag != ""
condition     = var.min_replicas >= 2
```

A future engineer cannot casually pin `latest` or scale to one replica. This is the "enforce structurally where you can" principle applied correctly, and it is the reason those two decisions will survive staff turnover.

**The salt key lifecycle encodes an incident lesson.** `prevent_destroy = true` plus `ignore_changes = [value]` means the credential-invalidating rotation described in runbook 4 cannot happen through a routine apply. The comment explains why. This is what it looks like when a runbook caveat becomes infrastructure.

**The ledger database is properly protected.** Zone-redundant HA, `prevent_destroy`, `public_network_access_enabled = false`, fourteen-day backup retention. Regional ledgers are the specification's stated source of truth and are treated accordingly.

**The break-glass module is genuinely dormant and genuinely auditable.** Purge protection, approvers-only data plane, diagnostics to the gateway workspace, and `ignore_changes = [value, expiration_date]` so Terraform will never revert an activated credential in the middle of an incident. Taking an existing principal ID rather than forcing group creation was a good adaptation — it works without directory write permissions.

**The central privacy guardrail is actually deployed.** `store_prompts_in_spend_logs: false` is present in the Terraform-rendered config that the Container App consumes, not only in the committed example. Given how much of the program's regulated-data argument rests on that one line, it is worth confirming explicitly: it is there.

**The Managed Redis substitution was handled correctly** — blocked by retirement policy, substituted, and the reason recorded in STATE.md rather than left as an unexplained divergence from the plan.

## 3. Defects To Fix Before The POC

### P1. There is no CI at all

There is no `.github/` directory. No workflow runs `terraform fmt -check`, `terraform validate`, `terraform plan` on pull requests, or any static analysis.

This repository provisions and manages live infrastructure — a gateway carrying every AI request in the organisation, a database holding the spend ledger, and Key Vault secrets. It is the highest-consequence code in the program and the only repository with no automated gate whatsoever. hometown at least has a workflow, even if it runs a third of its checks.

Specification consequence: TC-OPEN-02 states that `terraform plan` from a clean clone must produce the reviewed expected plan, with verification method "CI + AUDIT." Neither half exists.

**Fix:** a workflow running `terraform fmt -check -recursive`, `terraform init -backend=false`, and `terraform validate` on every pull request. That is roughly twenty lines, requires no credentials, and would catch formatting drift, syntax errors, and undeclared variables before they reach a human reviewer. Plan-on-PR with a read-only identity is the natural second step; static analysis (`tflint`, `checkov`) the third.

### P2. The only alert cannot fire — live infrastructure is effectively unmonitored

One alert exists:

```hcl
resource "azurerm_monitor_metric_alert" "gateway_availability" {
  severity    = 1                          # page
  criteria { metric_name = "Requests"
             operator    = "GreaterThan"
             threshold   = 1000000 }       # in a 5-minute window
}
```

A million requests in five minutes is roughly 3,300 per second. This alert will never fire. It is labelled severity 1 — page — and named `availability-burn`, so anyone auditing the resource list sees an availability page configured and reasonably concludes availability is monitored. **A dead alert that looks alive is worse than no alert**, because it displaces the question.

Roadmap 7.3 specifies four page-level classes (availability burn, sustained ledger write failures, state-store failover, internal errors above threshold) and five notify-level classes (budget thresholds at 50/80/100 percent, spend velocity anomalies, sustained fallback activation, nono bypass detections, attribution completeness dips). One is implemented and it is inert.

The observability module ships a Postgres diagnostic setting with the comment "ledger write failures are a page-level alert" — the telemetry is collected, no alert consumes it.

This matters more than it would pre-Stage-2 because **the infrastructure is applied and running**. Something is live and nothing will tell anyone if it stops.

**Fix:** the intent to defer *thresholds* until Stage 1 baselines is correct and should stand. But at least one alert must be able to fire now. A 5xx-count or failed-request-count alert with a deliberately conservative threshold, plus a Postgres availability alert, gives real coverage today and can be tightened later. If a class genuinely cannot be implemented until baselines exist, do not ship an inert placeholder for it — leave it out and record the gap, so the resource list does not misrepresent coverage.

### P3. The Container App has no health probes

The `container` block declares no `liveness_probe`, `readiness_probe`, or `startup_probe`.

Consequences on a platform that is already live:

- **Traffic reaches replicas before LiteLLM is ready.** Container Apps considers a container running once the process starts; without a readiness probe it will route requests during startup, while the gateway is still loading config and connecting to Postgres and Redis.
- **A broken revision still receives traffic.** The startup command writes the config to `/tmp` and execs LiteLLM. If the config is malformed, the process may start and then fail to serve. Without a liveness probe nothing restarts it and nothing withholds traffic.
- **Rolling upgrades cannot be safe.** REQ-REL-05 states that replica changes and rolling upgrades occur without request loss. Without readiness gating, the platform has no signal telling it when a new revision is able to serve, so the requirement cannot be met.

There is a small irony worth noting: the operations runbook instructs the intern to `curl` `/health/liveliness` to confirm the gateway is up. The platform itself never checks.

**Fix:** add `readiness_probe` and `liveness_probe` blocks against LiteLLM's health endpoints, plus a `startup_probe` with a tolerant failure count so slow first boots are not killed. This is perhaps fifteen lines and it converts availability from a hope into a platform-enforced property.

### P4. Data-class enforcement is entirely absent

`DATA_CLASS_ENFORCEMENT_v0.1.md` is not present in `specs/`, and no `data_class`, `classification`, or equivalent appears anywhere in the Terraform or the gateway configuration.

This is the popeye half of C2 — the regulated-data gap, the one I described as capable of stopping a program rather than merely embarrassing it in review. The program-level control document may exist in the fiskroad repository, but the *enforcement point* is here, and it has nothing.

Concretely, TC-REG-03 — a key scoped to a regulated feature is refused a non-approved model, with a distinct policy error class — cannot be demonstrated. When a partner reviewer asks which model sees consumer financial data and what prevents the wrong one from seeing it, the answer today is a document in another repository.

**Fix:** land the specification in this repository, then implement the minimum viable version: an approved-model registry as source-controlled configuration mapping each model deployment to a maximum data class, `data_class` on team and key metadata, and allowlists generated from the registry rather than hand-maintained. The allowlist mechanism already exists in LiteLLM; what is missing is deriving it from classification rather than by hand.

## 4. Significant, But Not POC-Blocking

**S1. The Redis key is a literal in Terraform state, contradicting the comment above it.** Three secrets use `key_vault_secret_id` references; two use literal `value =`. The `litellm-config` literal is fine and documented under ADR-002 — it carries routing metadata, no credentials. `redis-password` is different:

```hcl
secret {
  name  = "redis-password"
  value = var.redis_primary_access_key
}
```

That places the Redis access key in Terraform state as plaintext, directly under a comment reading "Values never appear in Terraform state as literals here." The backend is Entra-authenticated Azure Storage, so this is not exposed — but it is a different security posture than the other three secrets and it is not the one the comment claims. Store it in Key Vault and reference it, or amend the comment to state exactly which secrets are literals and why.

**S2. Single model, no fallback chain — a POC exit criterion cannot be met.** The rendered config declares one model (`twg-foundry`) and no `fallbacks:` block. TC-REL-02 requires demonstrating that a provider failure is absorbed by fallback; with one backend there is nothing to fall back to. TC-COST-04, the cloud-split dimension, is likewise undemonstrable. The kickoff descope rules explicitly permit running single-provider — but they also require saying so, and the exit criteria have not been amended to reflect it. Either add the Bedrock backend and a fallback chain for one model group, or amend the criteria and state the limitation in the baseline document.

**S3. Internal DNS is still a comment.** `gateway-azure.ai.twg.internal` does not exist; the section is a `TODO(stage-2)`. Roadmap section 5's routing rule and the Intune desktop rollout both depend on a stable name. Everything currently points at the raw Container App FQDN, which changes if the app is recreated — meaning a rebuild silently breaks every configured client. The blocker was zone ownership; that decision is worth forcing now rather than after clients have hardcoded the generated name.

**S4. The roadmap filename convention diverged from hometown.** This repository has `specs/ROADMAP_integration_popeye.md`; hometown consolidated to `specs/ROADMAP.md`. The fiskroad glossary now asserts that every project's team roadmap is `specs/ROADMAP.md` and that the `ROADMAP_integration_*` names are retired — which is currently false for popeye. Rename, and update `specs/README.md` and `STATE.md` references.

**S5. STATE.md's date is stale.** The header reads `Last updated: 2026-07-10`, but the content describes infrastructure applied and Foundry config delivered afterwards. The body is current; the date is not. For a file whose entire purpose is telling a returning engineer where things stand, the timestamp being wrong undermines the one thing it is for.

**S6. Terraform state holds four generated secrets.** The Postgres admin password, master key, salt key, and Redis key all live in state. Entra-authenticated Azure Storage is the right backend and access is presumably restricted, but the specification's guardrail — "the state backend must be encrypted and access-controlled before first apply" — deserves a recorded confirmation that it was, naming who holds access. Right now it is asserted in a spec and unverified in the repository.

## 5. The Cross-Repository Pattern, One Last Time

Three repositories, three verification postures, none of which validates artifacts against reality:

- **Bluto** has an elaborate governance apparatus — 224 documents against 33 source files — that did not catch unkeyed SHA-256 where the spec required HMAC.
- **hometown** has seventeen verifier scripts, four of which run in CI, two of which assert that a known defect is still present.
- **popeye** has no CI at all, and its single alert cannot fire.

Popeye's version is the cheapest to fix and has the highest consequence, because this is the repository that manages live infrastructure. Twenty lines of workflow and one alert that can actually trigger would move it from the weakest verification posture in the program to a defensible one.

The architecture across these three repositories is good. The specifications are better than most organisations produce. What is consistently missing is the last step — proving that the thing described is the thing running — and a partner reviewer will find that by asking to see something execute rather than by reading anything.

## 6. Fix List, In Order

1. **P1** — add a CI workflow: `fmt -check`, `init -backend=false`, `validate`. Twenty lines, no credentials.
2. **P2** — make at least one alert capable of firing; remove or fix the inert placeholder so the resource list does not overstate coverage.
3. **P3** — add readiness, liveness, and startup probes to the Container App.
4. **P4** — land the data-class enforcement spec here and implement the approved-model registry.
5. **S1** — move the Redis key into Key Vault, or correct the comment.
6. **S2** — add the second backend and a fallback chain, or amend the exit criteria and say so.
7. S3 through S6 as capacity allows; S4 and S5 are minutes.

Items 1 through 3 are a morning's work between them, and they close the gap between infrastructure that is applied and infrastructure that is operated.
