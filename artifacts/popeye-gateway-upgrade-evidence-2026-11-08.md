# Gateway Patch Re-pin Evidence (LiteLLM 1.106.2 → 1.106.7) — 2026-11-08

This patch re-pin was triggered by the Wiz scan of 2026-11-08, which found CVE-2026-111497 (KEV) in `libbrotli*`, and by advisory GHSA-w4c7-34wj-hqm8 (critical, `< 1.106.5`).

Redacted: no keys, DSNs, passwords or identifiers beyond the tag, the digest and revision names. Runbook: `specs/POPEYE_GATEWAY_UPGRADE_RUNBOOK_v0.1.md`, section "Patch re-pin 1.106.2 → 1.106.7".

## Pre-apply

- backup: `pre-litellm-1067-202611082029` (Customer On-Demand), completed 2026-11-08T20:36:34Z
- previous-image: `ghcr.io/berriai/litellm:v1.106.2@sha256:7294b90f868c5c38c99b83021c7ba46f9b439e95f8e32964c925c7d2563a03f7`
- target-image: `ghcr.io/berriai/litellm:v1.106.7@sha256:be24d7da11f4063ca23fbff6689bac5ded14fe4fc645e07f36588636969f1c27`

| Check | Result |
|---|---|
| Upstream GHSA list vs `config/litellm-advisory-ranges.json` | 1 new: GHSA-w4c7-34wj-hqm8. Added. v1.106.2 now FAILS the gate; v1.106.7 PASSES |
| Target digest equals GHCR `docker-content-digest` for v1.106.7, and the pulled RepoDigest | PASS |
| Prisma migrations, 1.106.2 vs 1.106.7 (`litellm_proxy_extras/migrations`) | 213 vs 213: no new migrations |
| First full plan | 0/2/0. It also changed Postgres `zone` 1→3 and standby 3→1, which is HA failover drift. STOPPED per runbook |
| Fix | `lifecycle.ignore_changes = [zone, high_availability[0].standby_availability_zone]` on the gateway Postgres server. No infrastructure change |
| Re-plan summary | 0 to add, 1 to change, 0 to destroy |
| Resources changed | `module.service.azurerm_container_app.gateway` image only |
| Salt key, Postgres, Redis or networking changes | none — PASS |

## Apply and verification (2026-11-08)

The saved plan was applied: 0 added, 1 changed, 0 destroyed. The new revision is `popeye-stage1-stage2-eastus2-app--0000006`. It was Healthy about 75 s after apply. `--0000005` is deactivated.

| Item | Result |
|---|---|
| GW-01 running image == pin (`v1.106.7@sha256:be24d7da…1c27`) | PASS |
| GW-01 active revision Healthy, Running, 2 replicas, 100% traffic | PASS |
| GW-04 terminationGracePeriodSeconds | 45 — PASS |
| GW-04 readiness probe path | `/health/readiness` — PASS |
| GW-04 PID 1 (both replicas) | `/app/.venv/bin/python3 /app/.venv/bin/litellm --config …` — PASS |
| GW-05 env names include DISABLE_ADMIN_UI, LITELLM_LOG, PROXY_BATCH_WRITE_AT | PASS |
| In-replica `/health/liveliness` (both replicas) | 200 / 200 — PASS |
| In-replica `/health/readiness` | 200 on replica fvg46. On replica cbpsn the exec API returned 429 (rate-limited), but the platform readiness probe on the same path reports Healthy — PASS |
| GW-05/GW-06 boot log: no MOVED/CROSSSLOT/ConnectionError | PENDING: `az monitor log-analytics query` needs interactive sign-in on this workstation. Check in the portal (`ContainerAppConsoleLogs_CL`, `RevisionName_s == '…--0000006'`) |
| `terraform plan -detailed-exitcode` after apply | 0 — PASS |
| `scripts/Test-LitellmAdvisoryRange.py` | exit 0 — PASS |

Rollback: re-pin the previous image reference above. No Postgres restore is needed, because no migrations ran. v1.106.2 fails the advisory gate, so the re-pin needs the emergency exception described in the runbook.
