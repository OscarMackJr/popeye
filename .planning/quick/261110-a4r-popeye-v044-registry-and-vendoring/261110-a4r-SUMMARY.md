---
quick_id: 261110-a4r
status: complete
---

Done on branch `feat/popeye-v0.4.4-registry` (PR open, not merged).

- Vendored fiskroad 6e63084: vocabulary v0.5 `db1a9b13…`, task_types `c2c7e9ad…`, roles `22eb1ae6…` (SHA-256 over LF; matches the hash the user gave for vocabulary).
- Agent registry `config/agent-registry.example.yaml`; `scripts/Test-AgentRegistry.py` passes locally and rejects all 10 negative fixtures; a tampered vendored file fails the hash check. The existing REQ-DCE-05 class check still passes on v0.5.
- REQUIREMENTS.md: TSK-01..09 added (87 v1 requirements, all mapped); CON-04 fields updated; REG-01 reworded.
- ROADMAP.md: Phases 2, 5, 6 gain TSK requirements and success criteria.
- STATE.md: REQ-AGT-22..30 status table. REQ-AGT-26 implemented; others not measured (issuer not built).

Open: the `liam` registry values (grants, purposes, tenant) are POC seeds needing program confirmation.
