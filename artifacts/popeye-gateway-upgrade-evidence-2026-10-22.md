# Gateway Upgrade Evidence (LiteLLM 1.106.x) — 2026-10-23

Plan 01-07 (D-01, D-02, D-03; GW-01, GW-04, GW-05). Redacted: no keys, DSNs, passwords or identifiers beyond the tag, the digest and revision names. Runbook: `specs/POPEYE_GATEWAY_UPGRADE_RUNBOOK_v0.1.md`.

## Pre-apply (Task 2)

backup: pre-litellm-1106-20261023 (Customer On-Demand), completed 2026-10-23T14:54:49Z
previous-image: ghcr.io/berriai/litellm:v1.90.3 (pulled by tag; GHCR digest on 2026-10-23 sha256:e4b91a2de9367ab0987baaa767b2283390badd5a361357993de1a05f027edc22)
target-image: ghcr.io/berriai/litellm:v1.106.2@sha256:7294b90f868c5c38c99b83021c7ba46f9b439e95f8e32964c925c7d2563a03f7

| Check | Result |
|---|---|
| Plan 01-04 complete (Redis publicNetworkAccess Disabled, gateway healthy) | PASS (2026-10-23) |
| Pin-day re-check: GHSA list unchanged, v1.106.2 latest stable 1.106.x, digest matches GHCR | PASS |
| foundry_scope_id set in terraform.tfvars | yes |
| Plan summary | 0 to add, 1 to change, 0 to destroy |
| Resources changed | module.service.azurerm_container_app.gateway only (image, args `exec`, 3 env vars, readiness path, startup threshold 18→60, grace 0→45, config secret set) |
| Salt key, Postgres, Redis or networking changes | none — PASS |

## Apply and verification (Task 3, 2026-10-23)

Applied the saved plan: 0 added, 1 changed, 0 destroyed (29 s). New revision `popeye-stage1-stage2-eastus2-app--0000005`.

| Item | Result |
|---|---|
| GW-01 running image == pin (`v1.106.2@sha256:7294b90f…a03f7`) | PASS |
| GW-01 active revision Healthy, Running, 2 replicas | PASS |
| GW-04 terminationGracePeriodSeconds | 45 — PASS |
| GW-04 readiness probe path | `/health/readiness` — PASS (liveness and startup on `/health/liveliness`) |
| GW-04 PID 1 | `/app/.venv/bin/python3 /app/.venv/bin/litellm --config` (litellm, not sh) — PASS |
| GW-05 env names include DISABLE_ADMIN_UI, LITELLM_LOG (and PROXY_BATCH_WRITE_AT) | PASS |
| In-replica `/health/readiness` and `/health/liveliness` | 200 / 200 — PASS |
| GW-05/GW-06 boot log `coordination_redis: using a standalone Redis…`, no MOVED/CROSSSLOT/ConnectionError | PENDING (portal Log Analytics query) |
| `terraform plan -detailed-exitcode` after apply | 0 — PASS |
| `scripts/Test-LitellmAdvisoryRange.py` | exit 0 — PASS |

Note: on the operator workstation, `az containerapp logs show` and `az monitor log-analytics query` fail certificate verification (TLS-intercepting proxy on Azure data-plane hosts). Management-plane calls and `az containerapp exec` work. Console logs are read in the portal.
