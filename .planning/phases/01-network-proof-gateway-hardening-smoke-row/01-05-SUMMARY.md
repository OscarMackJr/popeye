---
phase: 01-network-proof-gateway-hardening-smoke-row
plan: 05
status: in-progress at Task 3 checkpoint
requirements: [NET-03, MVP-01]
key-files:
  modified:
    - modules/gateway-service-azure/outputs.tf
    - envs/azure-eastus2/variables.tf
    - envs/azure-eastus2/main.tf
    - envs/azure-eastus2/outputs.tf
---

# Phase 01 Plan 05: Env DNS Terraform and Reader DSN Secret (partial)

Status: Tasks 1 and 2 done and committed; Task 3 (operator apply and verification) pending.

## Completed

- Task 1 (071e489): module outputs `default_domain` and `static_ip`; root variables `manage_env_dns_zone` (default false) and `caller_vnet_id` (validated, default empty).
- Task 2 (3bf47fc): count-gated env private DNS zone, `*` and `@` A records, stage link and optional caller link (registration disabled, names from module outputs); `random_password.ekg_cube_reader` and Key Vault secret `litellm-reader-dsn`; root outputs `env_default_domain` and `env_static_ip`.

## Verification run locally

- `terraform fmt -check -recursive`: pass.
- `terraform init -backend=false` and `validate`: pass.
- `terraform plan` was NOT run (no backend or Azure auth by design). The default-vars plan expectation (only the reader password and secret added) is for the operator to confirm.
- No `ashyglacier` or `10.60.0.108` in main.tf. Salt key block, image tag and Redis resources untouched.

## Deviations

None.

## Pending: Task 3 (operator)

Preflight decision is `env-dns-owner: networking-owns`: apply with defaults (adds only the reader password and secret), confirm `litellm-reader-dsn` via `az keyvault secret list` names only, run the DNS check via run-command, and record `env-dns-branch-taken:` and `env-dns-resolution:` (likely `blocked-on-networking` until the zone exists) in the preflight file. Then `terraform plan -detailed-exitcode` must exit 0.
