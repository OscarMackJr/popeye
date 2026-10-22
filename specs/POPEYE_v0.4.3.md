# Popeye v0.4.3 — Agent Key Identifier Format

Version: 0.4.3
Status: **Ratified 2026-10-19**, jointly with the v0.4.3 package (see Ratification Record at the end).
Repository: popeye (`specs/`)
Amends: `POPEYE_v0.4.1.md` §2.1 (exchange response) and §2.3 (ledger); `POPEYE_v0.4.2.md` §2.1 (introspection response).
Audience: popeye maintainer; nono maintainer.
Primary post-read action: implement before nono writes `AgentSessionRecord`.

---

## 1. Why

nono records the agent key's identifier as a fixed 16-byte `KeyId` so its supervisor records stay content-free without a second free-text exception (`NONO_v0.4.3` §4). That only works if popeye guarantees the identifier's shape.

## 2. The Rule

`key_id` for every agent key is a **UUID** (version 4 or 7), rendered in **lowercase canonical form** (`8-4-4-4-12`), unique, and never reused, including after revocation or expiry.

The same form appears everywhere the identifier does:

- the exchange response (`POPEYE_v0.4.1` §2.1);
- the revocation request (`POPEYE_v0.4.1` §2.4);
- ledger rows for agent-key requests (`POPEYE_v0.4.1` §2.3);
- issuance events (`POPEYE_v0.4.1` §2.5);
- the introspection response (`POPEYE_v0.4.2` §2.1).

This matches the program's existing identifier convention (`tenant_id_format` in `vocabulary.yaml`).

## 3. Requirements

| REQ | Requirement | TC | Test criteria | Method |
|---|---|---|---|---|
| REQ-AGT-20 | Every issued agent `key_id` is a lowercase canonical UUID | TC-AGT-20 | 1,000 issued keys all match `^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`; no duplicates | CI |
| REQ-AGT-21 | The same `key_id` string appears unchanged in exchange, revocation, ledger, issuance event and introspection | TC-AGT-21 | One key followed through all five surfaces; byte-identical values | CI (live) |

---

## Ratification Record

| Field | Value |
|---|---|
| Decision | **Ratified**: agent `key_id` is a lowercase canonical UUID, identical on every surface |
| Date | 2026-10-19 |
| Ratified by | Oscar Mack (architecture and risk decisions) |
| Ratified together with | `NONO_v0.4.3.md`, `POPEYE_v0.4.3.md`, `LIAM_DESIGN_SPEC_v0.4.md`, `LIAM_TEST_SPEC_v0.4.md` (one package) |
| Scope ratified | §2 (the rule), §3 (REQ-AGT-20, -21) |
| Not ratified here | None specific to this amendment |
| Effect | Amends `POPEYE_v0.4.1` §2.1/§2.3 and `POPEYE_v0.4.2` §2.1 as stated. Implementation may start |
| Change control | A change to the identifier format requires a matching change to `NONO_v0.4.3` §4 and re-ratification of the package |
