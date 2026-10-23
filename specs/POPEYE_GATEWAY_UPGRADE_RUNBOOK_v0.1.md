# Popeye Gateway Upgrade Runbook v0.1

In-place upgrade of the LiteLLM gateway on Azure Container Apps to the pinned 1.106.x release (plan 01-07; D-01, D-02, D-03; GW-01, GW-04, GW-05). The pin lives in `envs/azure-eastus2/litellm-pin.auto.tfvars`, which holds only the tag and digest. CI checks it against `config/litellm-advisory-ranges.json`.

previous image reference: ghcr.io/berriai/litellm:v1.90.3 (running revision, pulled by tag; GHCR digest for v1.90.3 on 2026-10-23: sha256:e4b91a2de9367ab0987baaa767b2283390badd5a361357993de1a05f027edc22)

## Pin-day re-check (2026-10-23)

- Upstream GHSA list matches `config/litellm-advisory-ranges.json`: 17 advisories, none new.
- Latest non-prerelease 1.106.x release: `v1.106.2` (2026-10-21). `v1.107.0-rc.*` are prereleases and are not pinned.
- GHCR `docker-content-digest` for `v1.106.2` (OCI index): `sha256:7294b90f868c5c38c99b83021c7ba46f9b439e95f8e32964c925c7d2563a03f7`. This equals the committed pin.
- `scripts/Test-LitellmAdvisoryRange.py` exits 0.
- The local `terraform.tfvars` no longer sets `litellm_image_tag`, so the pin file is the single source of truth.

Never pin 1.91.0–1.100.3 (GHSA-7hp6-4w63-5g45), and never pin `latest` or an rc tag.

## Preconditions

1. Plan 01-04 is complete. Redis `publicNetworkAccess` is Disabled and the gateway is healthy (D-16 ordering).
2. The previous image reference is recorded above, read from `az containerapp show -n <app> -g <rg> --query "properties.template.containers[0].image" -o tsv`.
3. A Postgres backup point is taken or confirmed (D-02), using either:
   - `az postgres flexible-server backup create -g <rg> -s <pg server> -n pre-litellm-1106-<yyyymmdd>`, or
   - an automated backup with a restore point less than an hour old (`az postgres flexible-server backup list`).

   Record the backup name and the UTC time.
4. `foundry_scope_id` is set in `terraform.tfvars`, because the smoke call needs gateway identity RBAC on Foundry.

## Apply

One `terraform -chdir=envs/azure-eastus2 plan -out=<scratchpad>/upgrade.tfplan`, reviewed, then `terraform apply <scratchpad>/upgrade.tfplan`.

The expected diff touches only `module.service.azurerm_container_app.gateway`:
- image (`tag@digest`) and args (`exec litellm`)
- env (`DISABLE_ADMIN_UI`, `LITELLM_LOG`, `PROXY_BATCH_WRITE_AT`)
- probes (readiness `/health/readiness`, startup threshold 60)
- `termination_grace_period_seconds = 45`
- the rendered config secret

Stop without applying if the plan touches the salt key, Postgres, Redis or networking.

Assumption A1: if Container Apps rejects `tag@digest`, switch the module image to digest-only (`ghcr.io/berriai/litellm@<digest>`). The comment in `modules/gateway-service-azure/main.tf` shows the form. Then re-plan.

## Migration monitoring

- First boot of 1.106.x runs about 86 Prisma migrations, which are **one-way**.
- From 1.103.3 on, the proxy exits if a migration fails.
- The startup probe budget is 10 s x 60 (about 10 minutes).
- Watch `az containerapp logs show -n <app> -g <rg> --type console --follow` (or Log Analytics) until Prisma reports completion or failure.
- Prisma serializes concurrent replicas with a Postgres advisory lock (assumption A3). If two replicas conflict, restart them one at a time.

## Verification

Record each item as PASS or FAIL in `artifacts/popeye-gateway-upgrade-evidence-2026-10-22.md`. Record no identifiers beyond the tag, digest and revision name.

- GW-01: the running image equals `ghcr.io/berriai/litellm:<tag>@<digest>` from the pin file. The active revision is Healthy with at least 2 Running replicas.
- GW-04:
  - `terminationGracePeriodSeconds` is 45.
  - The readiness probe path is `/health/readiness`.
  - In a replica, `tr '\0' ' ' < /proc/1/cmdline` shows `litellm` as PID 1, not `sh`.
- GW-05/GW-06:
  - The boot log contains `coordination_redis: using a standalone Redis from general_settings`, with no MOVED, CROSSSLOT or ConnectionError lines.
  - Env names include `DISABLE_ADMIN_UI` and `LITELLM_LOG`.
- From inside a replica, `/health/readiness` and `/health/liveliness` both return 200.
- `terraform plan -detailed-exitcode` exits 0, and `scripts/Test-LitellmAdvisoryRange.py` exits 0.
- The cross-replica counter and SIGTERM-flush proofs are left for plan 01-08.

## Rollback

The migrations are one-way, so re-pinning the old tag alone is not a rollback. A database migrated by 1.106.x is not guaranteed to work with 1.90.3.

1. **Restore** Postgres to the pre-upgrade backup point, following Azure's Flexible Server restore docs. The usual target is a new server restored from that point, which is then swapped in (D-02).
2. **Re-pin** the previous tag and digest from the "previous image reference" line above in `litellm-pin.auto.tfvars`. 1.90.3 falls inside the GHSA-g5ff-637f-6q2m and GHSA-3cv6-jpf6-8222 ranges, so CI's advisory check fails it, and the re-pin needs a reviewed emergency exception rather than a normal PR.
3. Re-apply with Terraform. If a new server was restored, point `litellm-database-url` at it first.
4. Re-validate the ledger grants (`sql/ai_usage_grants_azure.sql`, `ekg_cube_reader` SELECT-only).

A new revision that never becomes ready, in single-revision mode, leaves the old revision serving traffic. By then the database may already be migrated, so treat it as a rollback anyway. Do not keep the old image running against a migrated database.

**Never rotate or recreate the salt key** during an upgrade or rollback. It encrypts the stored virtual-key secrets, and Terraform protects it with `prevent_destroy` and `ignore_changes`.
