# Redis Clustering-Policy Spike and Private Cutover Evidence — 2026-10-22/23

Method: `scripts/Invoke-PopeyeRedisPrivateCutover.ps1` run by the platform owner from an
az-authenticated workstation (plan 01-04, GW-06, D-15, D-16). Spike code ran inside a gateway
replica via `az containerapp exec`, read `REDIS_*` from the container env and printed PASS/FAIL
and exception class names only. No password, access key or full private IP was printed or captured.

policy: NoCluster (`redis_clustering_policy` default; not overridden in tfvars)

## Spike (stage A applied, public access still Enabled)

Revision: `popeye-stage1-stage2-eastus2-app--0000004`. Client: plain `redis.Redis(ssl=True)`, as LiteLLM uses.

| Check | Result |
|---|---|
| `REDIS_HOST` resolves into the private endpoint subnet | 10.60.3.0/27 — PASS |
| `incr_three_keys` | PASS |
| `multi_exec_two_keys` | PASS |
| `mget_three_keys` | PASS |
| `mset_two_keys` | PASS |
| `eval_lua_one_key` | PASS |
| `scan_prefix` | PASS |
| `del_spike_keys` | PASS |

No MOVED, CROSSSLOT or ResponseError, so the EnterpriseCluster fallback was not needed.

The first spike attempt (2026-10-22) hit the `az containerapp exec` per-app rate limit (429,
retry-after about 10 minutes). Nothing in Azure changed; the rerun after waiting gave the rows above.

## Stage B (public access Disabled)

| Check | Result |
|---|---|
| Stage B plan stop conditions (Postgres destroy/replace, salt key, container image) | none — PASS |
| Redis `publicNetworkAccess` after apply | Disabled — PASS (GW-06) |

## Health after stage B (2026-10-23)

| Check | Result |
|---|---|
| Revision restart, Running replicas | >= 2 — PASS |
| `/health/readiness` from inside a replica | success status — PASS |
| Last 200 console lines: ConnectionError / MOVED / CROSSSLOT | none — PASS |
| Spike rerun over private-only Redis | all rows PASS |
| `terraform plan -detailed-exitcode` | 0, no drift — PASS |
