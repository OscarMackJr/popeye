---
phase: 01-network-proof-gateway-hardening-smoke-row
plan: 07
subsystem: gateway-service
tags: [litellm, upgrade, container-apps, gw-01, gw-04, gw-05]
requires: [01-06]
provides:
  - LiteLLM v1.106.2 (tag@digest) running on revision --0000005, 2 healthy replicas
  - Upgrade/rollback runbook specs/POPEYE_GATEWAY_UPGRADE_RUNBOOK_v0.1.md
  - Pre-upgrade Postgres backup pre-litellm-1106-20261023
affects: [01-08 admin ceremony]
key-files:
  created:
    - specs/POPEYE_GATEWAY_UPGRADE_RUNBOOK_v0.1.md
    - artifacts/popeye-gateway-upgrade-evidence-2026-10-22.md
  modified:
    - scripts/Invoke-PopeyeRedisPrivateCutover.ps1
decisions:
  - "Pin stays v1.106.2@sha256:7294b90f…: GHSA list unchanged, latest stable 1.106.x, GHCR digest matches (2026-10-23)"
  - "tag@digest accepted by Container Apps; A1 digest-only fallback not needed"
  - "coordination_redis boot line is not observable under LITELLM_LOG=ERROR; GW-06 behavioral proof moves to the 01-08 cross-replica counter test"
metrics:
  tasks: 3
  files: 4
completed: 2026-10-23
---

# Phase 1 Plan 07: LiteLLM 1.106.x upgrade Summary

The gateway runs `ghcr.io/berriai/litellm:v1.106.2@sha256:7294b90f…` on revision `--0000005`, which is Healthy with 2 replicas. The upgrade was one in-place change (0 add, 1 change, 0 destroy, 29 s) made after an on-demand Postgres backup. Results:
- PID 1 is litellm.
- The grace period is 45 s and readiness uses `/health/readiness`.
- The hardened env vars are present.
- readiness and liveliness both return 200.
- There is no drift.

Evidence: `artifacts/popeye-gateway-upgrade-evidence-2026-10-22.md`.

## Commits
- db9acfa: pin-day re-check and upgrade/rollback runbook
- 21a4eff: pre-apply evidence (backup point, previous image, clean plan)
- f0218b9: upgrade verification; cutover health fails on unreadable logs

## Deviations from Plan

### Task 1 done by the orchestrator
The executor sandbox has no network, so the GHSA, release and GHCR digest checks ran in the main session. The previous image (v1.90.3, pulled by tag) and its digest on that date are recorded in the runbook for rollback.

### Log stream blocked by a TLS-intercepting proxy
`az containerapp logs show` and `az monitor log-analytics query` fail certificate verification on the operator workstation. Console logs were read in the portal (Log Analytics, `ContainerAppConsoleLogs_CL`).

### [Rule 1 - Bug] 01-04 Health log check could pass on an empty read
`Invoke-PopeyeRedisPrivateCutover.ps1` discarded stderr from `logs show`, so an unreadable log counted as clean. It now throws on an empty or failed read. The re-check in Log Analytics confirmed 0 MOVED/CROSSSLOT/ConnectionError in 22,826 rows from revision `--0000004`.

### GW-06 boot-log line not observable
The plan expected `coordination_redis: using a standalone Redis…` in the boot log. `LITELLM_LOG=ERROR` (GW-05) suppresses that INFO line. The new revision's console output is the banner and the Prisma query-engine line only, with no errors. The cross-replica counter proof in plan 01-08 covers GW-06 behavior.

## Known Stubs
None.

## Self-Check: PASSED (GW-01, GW-04 and GW-05 env verified; GW-06 log line deferred to 01-08 behavioral proof)
