# Vendored Fiskroad Contracts

These files are copied unchanged from the fiskroad repository. Do not edit them here; re-vendor from fiskroad and update this table.

- Source repository: fiskroad, `main` at `6e63084dc23e87c3decc80e1a0a2ba531459f705`
- Vendored: 2026-11-10, for `POPEYE_v0.4.4` (task binding and agent registry)
- Hashes are SHA-256 over LF line endings, as the program requires. `scripts/Test-AgentRegistry.py` normalizes CRLF to LF before hashing and fails CI if a file drifts from this table.

| Vendored file | Source path | Version | SHA-256 (LF) |
|---|---|---|---|
| `vocabulary.yaml` | `contracts/vocabulary.yaml` | 0.5 | `db1a9b135248ec7c988722213dc882dfd97bcf269423fe639f81eea04004f855` |
| `authz/task_types.yaml` | `contracts/authz/task_types.yaml` | 0.1 | `c2c7e9ad9a4ea5a64b97522b29bd018b448769aa12b2a722b85dabb1962bc9d0` |
| `authz/roles.yaml` | `contracts/authz/roles.yaml` | 0.1 | `22eb1ae641730b61ecb5932631ba441dc74445284ef4168adf126296100b5d70` |

History:

- 2026-11-10: vocabulary v0.4 (`dbe74c63d1f5df8680685159e9c0d12e6073a79a363315cc6ea5168d5e8b7f2d`) replaced by v0.5, which adds `task_id_format`, `task_type_format`, `task_states` and `task_binding`. `authz/task_types.yaml` and `authz/roles.yaml` were vendored for the first time.
