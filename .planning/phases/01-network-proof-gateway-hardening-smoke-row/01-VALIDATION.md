---
phase: 1
slug: network-proof-gateway-hardening-smoke-row
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-10-22
---

# Phase 1 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | No unit framework (project convention): PowerShell check scripts with `Add-Result` (PASS/FAIL), Python fixture checks, `terraform fmt/validate` |
| **Config file** | none — Wave 0 adds `scripts/Test-LitellmAdvisoryRange.py` + `config/litellm-advisory-ranges.json` + fixtures |
| **Quick run command** | `terraform fmt -check -recursive && terraform -chdir=envs/azure-eastus2 validate && python scripts/Test-LitellmAdvisoryRange.py --self-test` |
| **Full suite command** | quick command + `Test-PopeyeAzureVerificationVm.ps1`, `Test-PopeyeVerificationVm.ps1`, `Test-PopeyeGatewayLockdown.ps1`, `Invoke-PopeyeSmoke.ps1`, `Test-PopeyeVerificationPsql.ps1` |
| **Estimated runtime** | ~30 seconds (quick); full suite is ceremony-paced (VM/Bastion) |

---

## Sampling Rate

- **After every task commit:** Run quick run command
- **After every plan wave:** Run quick command + any control-plane script runnable from the workstation
- **Before `/gsd-verify-work`:** All VM-side scripts green with redacted evidence in `artifacts/`
- **Max feedback latency:** 60 seconds (quick)

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 01-02-T1, 01-05-T3, 01-09-T1 | — | — | NET-01..03 | — | Peering Connected both ways; PG + env zones linked to both VNets; PG public Disabled | control-plane | `pwsh scripts/Test-PopeyeAzureVerificationVm.ps1` (extended) | extend | ⬜ pending |
| 01-02-T2, 01-09-T1 | — | — | NET-04 | — | PG RFC1918 + 5432; gateway FQDN -> 10.60.0.108 + 443 | VM-side | `pwsh scripts/Test-PopeyeVerificationVm.ps1` (gateway FQDN added) | extend | ⬜ pending |
| 01-02-T1, 01-09-T1 | — | — | NET-05, NET-06 | — | No public IP; RDP only from AzureBastionSubnet; login roles limited | control-plane | `pwsh scripts/Test-PopeyeAzureVerificationVm.ps1` (NSG/role checks) | extend | ⬜ pending |
| 01-06-T1, 01-07-T3 | — | — | GW-01 | — | Running revision image = v1.106.x@sha256 digest | integration | `az containerapp show` image check + `/health/readiness` | ❌ W0 | ⬜ pending |
| 01-01-T1, 01-06-T3 | — | — | GW-02 | — | CI fails on GHSA-affected pin | fixture | `python scripts/Test-LitellmAdvisoryRange.py --self-test` | ❌ W0 | ⬜ pending |
| 01-03-T2, 01-08-T2 | — | — | GW-03 | — | User key on `/key/*`, `/user/*`, `/utils/*` -> 403; UI locked | integration (VM) | `pwsh scripts/Test-PopeyeGatewayLockdown.ps1` | ❌ W0 | ⬜ pending |
| 01-06-T1, 01-07-T3, 01-08-T2 | — | — | GW-04 | — | SIGTERM flushes batched spend; grace period set | integration | revision swap N sent = N rows; `az containerapp show` spec check | ❌ W0 | ⬜ pending |
| 01-06-T2, 01-07-T3 | — | — | GW-05 | — | TTL <= 30, client creds false, LOG=ERROR, no prompt storage | static | grep of rendered YAML / `terraform validate` | ❌ W0 | ⬜ pending |
| 01-04-T3, 01-08-T2 | — | — | GW-06 | — | Redis counters shared across replicas; public access Disabled | integration | `az resource show` publicNetworkAccess + budget 422 on both replicas | ❌ W0 | ⬜ pending |
| 01-03-T1, 01-08-T2 | — | — | MVP-01 | — | Exactly one attributed ledger row; evidence redacted | e2e | `Invoke-PopeyeSmoke.ps1` then `Test-PopeyeVerificationPsql.ps1 -RequestId` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `scripts/Test-LitellmAdvisoryRange.py` + `config/litellm-advisory-ranges.json` + fixtures — GW-02
- [ ] `envs/azure-eastus2/litellm-pin.auto.tfvars` + `.gitignore` negation — GW-01/GW-02
- [ ] `scripts/Test-PopeyeGatewayLockdown.ps1` — GW-03
- [ ] `scripts/Invoke-PopeyeSmoke.ps1` — MVP-01
- [ ] `sql/ai_usage_grants_azure.sql` — MVP-01 reader grants
- [ ] `Test-PopeyeVerificationPsql.ps1` extended with `-RequestId` / key-hash assertions (read-only SELECT) — MVP-01
- [ ] `.gitignore` entries for raw evidence (`artifacts/*.raw*`, `artifacts/**/*.tmp`)

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Peering ownership recorded; env DNS zone ownership decision | NET-01, NET-03 | Depends on networking team reply | Record owner + date in evidence file |
| Administrator Login only with written approval | NET-06 | Approval is an out-of-band artifact | Reference approval in evidence |
| Admin ceremony (master key use, smoke key mint) | MVP-01 | Requires operator identity via Bastion | Follow ceremony runbook; record KV audit refs |
| Redis clustering policy spike | GW-06 | Live Azure Managed Redis behavior | Spike `NoCluster` vs `EnterpriseCluster`; record result |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 60s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
