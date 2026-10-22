# Popeye v0.4 — Agent Principals, Purpose Labels, Run Metering

Version: 0.4
Status: Draft. **Recovered 2026-10-19 from the August 2026 design session; header now recovered too, so the whole document is original text.**
Repository: popeye. Owner of gap G2's identity and metering halves.
Primary post-read action: note §5 — most of this revision is about what popeye refuses to absorb. The additions themselves are small.

**Carried forward from v0.3 and still outstanding:** registry re-keyed to the five program data classes, vocabulary vendored with the conformance check, `ENDPOINT_DETECTION_CONTRACT` extracted to `specs/`. Those are entry criteria for POC-2, not v0.4 work.

---

## 1. The Shape Of This Revision

popeye's contribution to governed agency is deliberately thin: **carry three more opaque labels, and meter runs correctly.** Everything about what a purpose *means* or what an action *does* lives elsewhere. The gateway stays semantics-blind (REQ-PGM-03), and this document exists as much to record that boundary as to add capability.

---

## 2. Agent Principals (G2)

### 2.1 Key issuance

Virtual keys gain three metadata fields from `PROGRAM_SHARED_VOCABULARY_v0.4` §3:

- `principal_type` — `user` | `application` | `agent`
- `agent_id` — required when type is `agent`
- `on_behalf_of` — required when type is `agent`; the delegating principal's identifier

Issuance validates: type is one of three; `agent` carries both `agent_id` and `on_behalf_of`; `on_behalf_of` is not itself an agent (REQ-VOC-10, onward delegation refused).

### 2.2 Agent key lifecycle — the part that matters operationally

An agent key is **short-lived by default**. An agent that runs for twenty minutes should not hold a credential for ninety days. Recommended default: expiry measured in hours, issued per run or per session.

This is the concrete governance win from the principal-type work, and it is worth stating plainly: a long-lived agent credential on a workstation is the shadow-AI problem returning wearing a costume.

### 2.3 Ledger

`principal_type`, `agent_id` and `on_behalf_of` are recorded on every request. Cost rolls up to `on_behalf_of`; activity attributes to `agent_id`. Both are queryable dimensions — "what did agents spend on behalf of the servicing team" is the question this enables.

| REQ | Requirement | TC | Test criteria | Method |
|---|---|---|---|---|
| REQ-AGT-01 | Every key carries a valid principal type; agents carry `agent_id` and `on_behalf_of` | TC-AGT-01 | Issuance rejects an agent key missing either field | CI |
| REQ-AGT-02 | Onward agent delegation is refused at issuance | TC-AGT-02 | Issuing an agent key whose `on_behalf_of` is an agent fails | CI |
| REQ-AGT-03 | Ledger rows carry principal type and, for agents, both identifiers | TC-AGT-03 | Live verifier asserts non-null on agent traffic | CI (live) |
| REQ-AGT-04 | Agent keys support short expiry | TC-AGT-04 | An expired agent key is refused with a distinct error | CI |

---

## 3. Purpose As An Opaque Label (G3)

The key carries `purpose`, validated against the vendored vocabulary list — **nothing more.** popeye does not know what `servicing` means, which fields it permits, or which groups grant it. It validates the string, records it, and enforces one relationship it was handed:

**The one prohibition popeye enforces:** the purpose/class pairing rule from vocabulary §2.4 — `analytics` and `marketing` keys cannot request models approved for `regulated-financial` or above. This is the same shape as the existing data-class enforcement: a relationship between two labels, no content inspection.

| REQ | Requirement | TC | Test criteria | Method |
|---|---|---|---|---|
| REQ-PUR-06 | Purpose values validate against the program list at issuance | TC-PUR-06 | A key with an invented purpose fails | CI |
| REQ-PUR-07 | The purpose/class prohibition is enforced at request time | TC-PUR-07 | An `analytics` key requesting a regulated-approved model is refused with a policy error | CI |

---

## 4. Run Metering (G2)

Requests carry an optional `run_id` in metadata, recorded on the ledger row.

**popeye does not compute run totals.** It records the label; totals are derived by joining ledger rows on `run_id` in the semantic layer. A cost computed in two places will eventually disagree, and the ledger is the single source of truth for spend.

One new alert class: **run cost exceeding a threshold** — an agent that has made 400 calls in one run is the runaway case the program was built to catch, and it is invisible to per-request rate limits. Threshold conservative and tunable, consistent with the v0.3 alerting posture.

| REQ | Requirement | TC | Test criteria | Method |
|---|---|---|---|---|
| REQ-RUN-01 | `run_id` is recorded when supplied | TC-RUN-01 | Three requests sharing a `run_id` produce three rows with that value | CI (live) |
| REQ-RUN-02 | A run exceeding the cost threshold raises an alert | TC-RUN-02 | Synthetic run breaches the threshold; alert fires | DEMO |

---

## 5. What popeye Refuses To Absorb (REQ-PGM-03)

Every item below will be proposed by someone during POC-2. The answer is no, and the reason is the same each time: a gateway that understands business semantics is a gateway that can never be replaced.

| Proposal | Correct owner |
|---|---|
| "Have the gateway check whether this purpose permits this field" | hometown |
| "Have the gateway execute the approved action" | olive |
| "Have the gateway decide which tools an agent may call" | olive |
| "Have the gateway hold the approval queue" | olive |
| "Have the gateway resolve `on_behalf_of` to a directory group" | the authorization path in hometown/olive |
| "Have the gateway store the run's assembled context" | nobody — no prompt content in governed stores |

**No write credentials to divisional systems in popeye, ever** (REQ-PGM-01).

---

## 6. Deferred

- **Tool-call metering.** Tool calls are not model calls and do not belong in the spend ledger. When olive meters tool executions, it does so in its own execution record. Revisit only if tool calls acquire per-call vendor costs.
- **Per-run budgets.** Budgets remain per key. A short-lived per-run key achieves the same outcome with existing machinery — prefer that over new budget scoping.
