---
quick_id: 261114-cmu
description: Apply ceremony runbook review fixes and add gateway Key Vault audit diagnostic setting
---

1. Terraform: add an `AuditEvent` diagnostic setting for the gateway Key Vault to the gateway Log Analytics workspace (`modules/gateway-observability-azure`, wired from `envs/azure-eastus2`). Without it, the runbook's step 10.4 audit query reads nothing. Run fmt and validate.
2. Runbook `specs/POPEYE_MVP_CEREMONY_RUNBOOK_v0.1.md`:
   - Step 3 checks healthy and unhealthy counts, not just HTTP 200.
   - Step 7 adds a spend > 0 check before the budget probe.
   - Step 9 filters revisions with `ConvertFrom-Json` (az.cmd mangles `--query`) and records the restart gap, with an inconclusive rule.
   - Step 10 adds `az logout` and requires SecretGet rows > 0.
   - 0d gets a log pre-check, and a new 0e lists the pre-checks.
   - Step 4 is labelled as a workstation step, `$oid` is lower-cased, and the `kusto` fence labels are removed.
