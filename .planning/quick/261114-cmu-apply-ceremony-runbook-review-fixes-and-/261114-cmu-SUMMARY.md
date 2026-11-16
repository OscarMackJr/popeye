---
quick_id: 261114-cmu
status: complete
completed: 2026-11-14
---

The gateway Key Vault now has an `AuditEvent` diagnostic setting (`popeye-stage1-stage2-eastus2-kv-diag`) to the gateway workspace in Terraform. `terraform fmt` and `validate` pass. It is not applied yet: the operator runs plan and apply before T0. A live check on 2026-11-14 showed the vault had no diagnostic settings.

The runbook's review fixes are applied:
- Step 3 checks health counts.
- Step 7 checks that spend is above zero.
- Step 9 filters revisions with `ConvertFrom-Json` and records the restart gap.
- Step 10 signs out of az and requires a non-empty audit read.
- 0d gets a log pre-check, and 0e lists the pre-checks.
- Smaller fixes: step 4 is labelled as a workstation step, `$oid` is lower-cased, and the `kusto` fence labels are removed.
