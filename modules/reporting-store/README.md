# reporting-store (Stage 3 stub)

Consolidated reporting store receiving both regional ledgers
(infrastructure plan section 4; roadmap section 5).

Not implemented until Stage 3, and deliberately so: placement (which
cloud) and mechanism (logical replication vs. scheduled job) are open
decisions (roadmap section 11), and the store's inputs do not exist
until two regional gateways are live.

When implemented, this module provides:

- One Postgres instance in the chosen cloud.
- Logical-replication subscription (or scheduled job) per regional
  ledger, spend-log table only.
- The `ekg_cube_reader` role via sql/ai_usage_grants.sql step 2.
- Freshness metric feeding the under-15-minutes p95 SLO.

Design rules: derived view, rebuildable from regional ledgers; carries
no prompt/completion content by construction (roadmap section 9), which
is what keeps cross-cloud consolidation low-sensitivity.
