# envs/reporting (Stage 3)

Consolidated reporting stack: the store both regional ledgers replicate
into, plus the Cube deployment reading it via ekg_cube_reader.

Blocked on two open decisions (roadmap section 11): host cloud, and
replication vs. scheduled-job consolidation. Module contract is
sketched in modules/reporting-store/README.md. Freshness SLO:
request-to-queryable under 15 minutes p95.
