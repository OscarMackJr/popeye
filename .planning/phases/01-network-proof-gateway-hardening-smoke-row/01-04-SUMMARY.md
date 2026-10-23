---
phase: 01-network-proof-gateway-hardening-smoke-row
plan: 04
subsystem: gateway-state
tags: [terraform, redis, private-endpoint, gw-06]
requires: []
provides:
  - Redis private endpoint in snet-private-endpoints (10.60.3.0/27) with privatelink.redis.azure.net
  - redis_clustering_policy variable (NoCluster validated)
  - Redis public network access Disabled (GW-06)
  - Operator cutover script and in-replica compat spike
affects: [01-06 coordination_redis, LiteLLM upgrade]
key-files:
  created:
    - scripts/Test-PopeyeRedisCompat.py
    - scripts/Invoke-PopeyeRedisPrivateCutover.ps1
    - artifacts/popeye-redis-spike-2026-10-22.md
  modified:
    - modules/gateway-state-azure/main.tf
    - modules/gateway-state-azure/variables.tf
    - envs/azure-eastus2/main.tf
    - envs/azure-eastus2/variables.tf
decisions:
  - "Clustering policy stays NoCluster: every plain-client spike row passed over the private endpoint (research assumption A5 confirmed)"
metrics:
  tasks: 3
  files: 7
completed: 2026-10-23
---

# Phase 1 Plan 04: Redis private cutover Summary

Managed Redis is reachable only through its private endpoint, and public network access is Disabled. The cutover took two separate applies with a NoCluster compatibility spike between them. After stage B the gateway passed the health checks: at least 2 replicas Running, readiness from inside a replica, clean console logs, a spike rerun and no Terraform drift. Evidence: `artifacts/popeye-redis-spike-2026-10-22.md`.

## Commits
- b3cea0d: Redis private endpoint, clustering policy variable, compat spike script
- 772070a: operator script for the cutover (stage A, spike, stage B, health)
- 173ef30: chunk in-replica payloads under the exec URL limit
- b0ff4eb: cut the spike to three exec sessions and stop on exec failure

## Deviations from Plan

### Operator script instead of manual steps
Task 3 ran through `scripts/Invoke-PopeyeRedisPrivateCutover.ps1` instead of hand-typed commands. The script checks plan stop conditions from the JSON plan and gates each apply on a typed YES.

### az containerapp exec limits
- exec sends its command in the URL and IIS returns 404 past about 2 KB, so payloads are zlib+base64 and staged in chunks under `/tmp`.
- exec is rate-limited per app. The first spike attempt hit a 429 (retry-after about 10 minutes). The spike was cut to three exec sessions and rerun after the wait. Health uses four sessions and may need the same wait.

## Known Stubs
None.

## Self-Check: PASSED (operator-run evidence; publicNetworkAccess Disabled, no drift)
