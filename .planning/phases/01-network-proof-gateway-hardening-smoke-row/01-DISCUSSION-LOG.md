# Phase 1: Network Proof, Gateway Hardening & Smoke Row - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md. This log preserves the alternatives considered.

**Date:** 2026-10-22
**Phase:** 01-network-proof-gateway-hardening-smoke-row
**Areas discussed:** Upgrade rollout, Admin access after lockdown, Smoke test mechanics, Env DNS zone + Redis private access

---

## Upgrade rollout

| Option | Description | Selected |
|--------|-------------|----------|
| In-place revision swap | terraform apply with new tag and digest; brief disruption acceptable | ✓ |
| Side-by-side revision | Multi-revision mode, shift traffic after checks | |
| You decide | Planner picks | |

| Option | Description | Selected |
|--------|-------------|----------|
| On-demand backup + rollback plan | Backup point before apply; restore-to-point rollback | ✓ |
| Rely on automatic PITR | Built-in point-in-time restore only | |

| Option | Description | Selected |
|--------|-------------|----------|
| Latest patched 1.106.x on pin day | Re-check GHSA; pin tag + digest | ✓ |
| Specific v1.106.2 | The version research verified | |

| Option | Description | Selected |
|--------|-------------|----------|
| Existing terraform.yml CI | Committed advisory-range file | ✓ |
| Live GitHub advisory API | Query at CI time | |
| Both | Committed gate + scheduled live job | |

## Admin access after lockdown

| Option | Description | Selected |
|--------|-------------|----------|
| Fully disabled UI | All admin via API/scripts | ✓ |
| Enabled, admin-only from peered VM | Internal-only UI | |

| Option | Description | Selected |
|--------|-------------|----------|
| Key-level allowed_routes now | Ingress blocking later with the route config | ✓ |
| Key-level + ingress block now | More Container Apps work early | |

| Option | Description | Selected |
|--------|-------------|----------|
| Master key from Key Vault, in-VNet only | Dedicated admin key in Phase 5 | ✓ |
| Mint a dedicated admin key now | Proxy-admin virtual key for scripts | |

The answer above conflicted with the existing verification procedure, which forbids operator/VM access to the master key. A follow-up question resolved it:

| Option | Description | Selected |
|--------|-------------|----------|
| Time-boxed KV grant, recorded | Secret-scoped grant for the ceremony window, then removed; procedure amended | ✓ |
| Mint from outside the VM | Still needs some grant | |
| Container Apps Job with gateway identity | No human sees the master key | |

## Smoke test mechanics

| Option | Description | Selected |
|--------|-------------|----------|
| Forward-compatible attribution | principal_type=user, Entra OID, tenant UUID, popeye-poc, user:<oid>, mvp-smoke | ✓ |
| Minimal POC values | team + tag only | |

| Option | Description | Selected |
|--------|-------------|----------|
| Repo script via run-command | Repeatable, redacted | ✓ |
| Manual from Bastion session | Interactive | |

| Option | Description | Selected |
|--------|-------------|----------|
| Read-only ekg_cube_reader query | Also proves the hometown read path | ✓ |
| Admin DB query | Privileged credential | |

| Option | Description | Selected |
|--------|-------------|----------|
| Short expiry + block after | ~24h, tiny budget, blocked not deleted | ✓ |
| Keep as reusable test key | Long-lived synthetic key | |

A Key Vault check found that `litellm-reader-dsn` doesn't exist yet. A follow-up question decided how to create it:

| Option | Description | Selected |
|--------|-------------|----------|
| Terraform password + in-VNet SQL | Generated into KV; SQL applied via run-command | ✓ |
| All manual from VM | Hand-created | |

## Env DNS zone + Redis private access

| Option | Description | Selected |
|--------|-------------|----------|
| Whatever networking replies | Terraform task ready, executed only if handed over | ✓ |
| Popeye Terraform owns it | Build now | |
| Networking owns it | Verify only | |

| Option | Description | Selected |
|--------|-------------|----------|
| PE subnet in 10.60.3.0/24 via Terraform | Private endpoint, privatelink.redis.azure.net, then Disabled | ✓ |
| Defer Redis PE | Record as debt | |

| Option | Description | Selected |
|--------|-------------|----------|
| Gateway VNet only | Callers never need Redis | ✓ |
| Both VNets | Diagnostics from the peered VM | |

| Option | Description | Selected |
|--------|-------------|----------|
| Redis PE before upgrade | Isolates failures | ✓ |
| Same apply as upgrade | Fewer revisions | |

## Claude's Discretion

- Config-hardening mechanics: `exec`, readiness probe, grace period, cache TTL, client-side credentials, log level
- How to verify that Redis backs the counters across replicas
- Advisory-range file format and the check script language
- Evidence file naming and `.gitignore` entries

## Deferred Ideas

- Ingress-level path restriction: Phase 4/5
- Dedicated admin key: Phase 5
- Live GHSA polling job
- Postgres Entra auth: v2
