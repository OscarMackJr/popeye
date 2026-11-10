# Popeye v0.4.4 — Task Binding, Agent Registry, and sit-cip / Nexus Introspection

Version: 0.4.4
Status: **Ratified 2026-11-10**, jointly with `NONO_v0.4.4.md` (one seam), via `DECISION_agent-key-service-scope.md` Revision 2. It implements decisions D-3 (`DECISION_task-binding-on-agent-key.md`) and D-4 (`DECISION_agent-key-sitcip-nexus-reads.md`). See the Ratification Record at the end.
Repository: popeye (`specs/`)
Amends:
- `POPEYE_v0.4.1.md` §2.1 (exchange request and response), §2.2 (issuance rules), §2.3 (ledger), §2.4 (revocation) and §5 O3 (closed);
- `POPEYE_v0.4.2.md` §2.1 (introspection response) and §2.3 (registered introspection callers).

Adds REQ-AGT-22 to -30.
Audience: popeye maintainer; nono, sit-cip, Nexus, hometown and olive owners.
Primary post-read action: implement; the requirements in this amendment are the acceptance criteria.

---

## 1. Why

Two ratified decisions change popeye's agent-key seam:

- **D-3:** task-based access control rides on the session agent key. popeye adds a task binding (`task_id`, `task_type`, `task_expires_at`) at mint and hosts the agent registry. That registry is the location `POPEYE_v0.4.1` §5 O3 left open.
- **D-4:** sit-cip and Nexus receive the agent key for reads and validate it through introspection, so they join the registered introspection callers.

Both keep popeye semantics-blind. It records which task a key belongs to and whether that task is still open. It never decides what a task type permits; that is Cedar policy, owned per system (`DECISION_policy-engine-cedar.md`).

---

## 2. Task Binding at Mint (amends `POPEYE_v0.4.1` §2.1, §2.2)

### 2.1 Exchange request and response

The exchange request body gains:

| Field | Type | Rule |
|---|---|---|
| `task_id` | lowercase canonical UUID | Required. Format per vocabulary v0.5 `task_id_format` |
| `task_type` | string | Required. Must be registered for the requesting `agent_id` (§3) |
| `task_ttl_seconds` | integer | Optional. Defaults to the key's TTL |

The response gains `task_id`, `task_type` and `task_expires_at`.

### 2.2 Issuance rules (added)

| Rule | Enforcement |
|---|---|
| `task_type` registered for this agent | Refused with a distinct error if `task_type` is not in the agent's registry entry |
| Task never outlives the key | `task_expires_at` = min(requested, key `expires_at`). popeye may shorten, never lengthen |
| Task binding is immutable | No call changes a key's `task_id` or `task_type`. A new task needs a new key |
| No task, no key | An exchange without a valid task binding is refused. An agent acts only inside a task (vocabulary v0.5 §5.3) |
| Same task, many keys | A `task_id` may appear on more than one key, for example a multi-day investigation across sessions. Each key keeps its own expiry |

### 2.3 Ledger (amends `POPEYE_v0.4.1` §2.3)

Ledger rows on agent-key requests gain `task_id` and `task_type`. Both are content-free: a UUID and a registered string.

---

## 3. The Agent Registry (closes `POPEYE_v0.4.1` §5 O3)

The agent registry lives in popeye, beside the model-approval registry. It is checked against the vendored `vocabulary.yaml` and `contracts/authz/task_types.yaml` in the same CI job. Each entry holds:

| Field | Meaning |
|---|---|
| `agent_id` | Registered agent identifier |
| `grants` | Agent grant role names from `contracts/authz/roles.yaml` `agent_grants` |
| `task_types` | Task types this agent may be bound to. Each must be in `task_types.yaml` |
| `purposes` | Purposes this agent may be minted with. A subset of the vocabulary |
| `tenants` | Tenants this agent may act in. The key still inherits the caller's tenant, and must also be in this set |

The registered introspection callers (§5) and relays (`POPEYE_v0.4.2` §2.6) are kept in the same registry. Adding an agent, grant, task type, caller or relay is a program decision, not configuration.

---

## 4. Task Close (amends `POPEYE_v0.4.1` §2.4)

A registered introspection caller that owns a task's anchor may close the task:

- sit-cip for `sitcip.investigation`;
- Nexus for `nexus.deal_review`;
- olive for `olive.proposal`.

Closing marks the task `closed` in popeye. From then on, every key bound to that `task_id` introspects as inactive, and gateway calls on those keys are refused.

nono's `nono.coding_session` tasks close by the existing session-end revocation; nono does not call task close.

- **Who may close.** Only the caller registered as the owner of that `task_type`. Any other caller is refused.
- **Idempotent.** Closing a closed task succeeds and changes nothing.
- **Never reopens.** A closed, expired or revoked task cannot be reopened. New work needs a new `task_id`.

---

## 5. Introspection (amends `POPEYE_v0.4.2` §2.1, §2.3)

- **Response.** For an active key, introspection additionally returns `task_id`, `task_type` and `task_expires_at`. A key whose task is no longer `open` returns `active: false` and nothing else, exactly like an expired key.
- **Registered callers.** POC set: `hometown`, `olive`, `sitcip`, `nexus`. sit-cip and Nexus are added by D-4 for **reads only**. Introspection confers identity, not capability; both enforce reads-only in their own policy (`contracts/authz/policies/common/guards.cedar`, `common.agent_no_direct_nexus_write`).
- **Caching.** Unchanged: at most 60 s, and never past `expires_at` or `task_expires_at`, whichever comes first. Task close therefore reaches services within 60 s.

---

## 6. Exposure Statement

The session agent key can now reach sit-cip and Nexus as well as the gateway, hometown and olive. The original `DECISION_agent-key-service-scope` mitigations apply unchanged: short TTL, session-end revocation, profile allowlist and WFP fence, and introspection conferring no capability.

The task binding narrows exposure further: closing a task ends every key bound to it, whatever the key's own TTL.

**Residual:** a compromised sit-cip or Nexus could misuse a live key within its TTL. That is limited to the reads its policy permits and to what the key's own constraints allow. Writes are denied by shared policy and go through olive.

---

## 7. Requirements

| REQ | Requirement | TC | Test criteria | Method |
|---|---|---|---|---|
| REQ-AGT-22 | The exchange refuses a request with no task binding, a malformed `task_id`, or a `task_type` not registered for the agent | TC-AGT-22 | Each case fails with a distinct error; no key is minted | CI |
| REQ-AGT-23 | `task_expires_at` never exceeds the key's `expires_at` | TC-AGT-23 | Request a task TTL of 48 h on an 8 h key; the granted `task_expires_at` is ≤ `expires_at` | CI |
| REQ-AGT-24 | A key's task binding cannot be changed after mint | TC-AGT-24 | No popeye path accepts a task change for an existing `key_id` | CI |
| REQ-AGT-25 | Ledger rows on agent keys carry `task_id` and `task_type` | TC-AGT-25 | Live verifier asserts non-null task fields on agent traffic | CI (live) |
| REQ-AGT-26 | The agent registry is checked against `vocabulary.yaml` and `contracts/authz/task_types.yaml` | TC-AGT-26 | CI fails on a registry entry with an unregistered task type, purpose or grant | CI |
| REQ-AGT-27 | Only the owning caller can close a task; close is idempotent and never reopens | TC-AGT-27 | Close by a non-owner is refused; double close succeeds; a mint with a closed `task_id` is refused | CI |
| REQ-AGT-28 | After task close, every key bound to it introspects inactive and is refused at the gateway | TC-AGT-28 | Close a task with two live keys; both return `active: false`; a gateway call on either is refused | CI |
| REQ-AGT-29 | Task close reaches services within the cache bound | TC-AGT-29 | sit-cip and Nexus stubs that cache per §5 refuse a closed task's key within 60 s | CI (stub) |
| REQ-AGT-30 | sit-cip and Nexus are registered introspection callers, and are not relays | TC-AGT-30 | Introspection by each succeeds; presenting either as a relay identity is refused (REQ-AGT-19) | CI |

---

## Ratification Record

| Field | Value |
|---|---|
| Decision | **Ratified**, jointly with `NONO_v0.4.4.md` as one seam |
| Date | 2026-11-10 |
| Ratified by | Oscar Mack, program lead (architecture and risk decisions), via re-ratification of `DECISION_agent-key-service-scope.md` Revision 2 |
| Reviewed by | popeye and nono owners (approved, fiskroad PR #7) |
| Implements | `DECISION_task-binding-on-agent-key.md` (D-3) and `DECISION_agent-key-sitcip-nexus-reads.md` (D-4), ratified 2026-11-10 |
| Change control | Any change requires a matching change to `NONO_v0.4.4.md` and re-ratification of `DECISION_agent-key-service-scope.md` |
