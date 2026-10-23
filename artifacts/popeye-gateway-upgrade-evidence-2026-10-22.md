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
