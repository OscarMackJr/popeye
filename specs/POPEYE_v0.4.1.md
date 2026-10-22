# Popeye v0.4.1 — Agent Key Exchange

Version: 0.4.1
Status: **Ratified 2026-10-19**, jointly with `NONO_v0.4.1.md` (one seam). See Ratification Record at the end.
Repository: popeye (`specs/`)
Amends: `POPEYE_v0.4.md` (adds §2.4–§2.6); `POPEYE_CORRECTIONS_v0.3.md` §3.1 (the credential-injection bullet, for agent profiles).
Audience: popeye maintainer; nono maintainer; Liam implementer.
Primary post-read action: implement §2 before the Liam build reaches its end-to-end tests.

---

## 1. Why This Amendment Exists

`POPEYE_v0.4` §2 says agent keys carry `principal_type=agent`, `agent_id` and `on_behalf_of`, and are short-lived, issued per run or per session. It does not say **who asks for one, or how**. On the workstation, the only component in a position to ask is `nono-proxy`, which already holds the user's virtual key (`POPEYE_CORRECTIONS_v0.3` §3.1).

This amendment defines the issuance path nono calls. Its central property: **`on_behalf_of` is derived by popeye from the authenticated caller, never asserted by the endpoint.** An endpoint cannot mint an agent key on behalf of someone else, because it can only present its own user's key.

Everything in `POPEYE_v0.4` §1 still holds: this adds one issuance path and keeps popeye semantics-blind.

---

## 2. Agent Key Exchange

### 2.1 Interface (implementation detail is popeye's choice)

A popeye-side issuance path, reachable on the gateway FQDN, that accepts:

- **Authentication:** the caller's own virtual key, `principal_type=user`.
- **Body:** `agent_id`, `purpose`, `ttl_seconds` (requested).

and returns:

- `key` (the agent key secret), `key_id`, `expires_at`, `agent_id`, `purpose`, `on_behalf_of`, `principal_type="agent"`.

Whether this is a thin wrapper over the gateway's native key generation or a separate small service is popeye's decision. The gateway's admin credential never leaves popeye's side; the endpoint never holds it.

### 2.2 Issuance rules

| Rule | Enforcement |
|---|---|
| Caller must be a `user` key | An `application` or `agent` key calling the exchange is refused (REQ-VOC-10; `PROGRAM_SHARED_VOCABULARY_v0.4` §3.2) |
| `on_behalf_of` = the caller's own principal | Set server-side from the authenticating key; any `on_behalf_of` in the body is ignored |
| `agent_id` must be registered | Unknown `agent_id` is refused. The registry of agent IDs lives with the model-approval registry |
| `purpose` must be in the vendored vocabulary | Validated as in REQ-PUR-06 |
| `purpose` must be permitted to the caller | The agent key's purpose may not exceed what the user key carries (intersection, never union — vocabulary §3.2). If the user key carries no purpose list, only the requested purpose is checked against the vocabulary, and this gap is recorded (§4 O1) |
| TTL capped | `expires_at` = min(requested, program cap). Program cap for POC-2: 8 hours. popeye may shorten, never lengthen |
| Inherited constraints | Data-class ceiling, tenant and budget are inherited from the caller's key; the agent key can never exceed them |
| Purpose/class prohibition | Applies to the agent key at request time exactly as to any key (REQ-PUR-07) |

### 2.3 Ledger

Requests on an agent key record `principal_type=agent`, `agent_id`, `on_behalf_of` and `purpose` per `POPEYE_v0.4` §2.3, plus `key_id`. `key_id` is what joins a ledger row to a nono receipt (`NONO_v0.4.1` §5); `run_id` (§4 of v0.4) joins it to the ATE.

### 2.4 Revocation

The same path accepts a revocation for a `key_id`, authenticated with the user key that minted it. Revoking a key that is already expired or revoked returns success (idempotent). Revocation by anyone other than the minting user key is refused.

### 2.5 Issuance events

Every exchange and revocation is recorded as an issuance event (caller principal, `agent_id`, `purpose`, `key_id`, granted `expires_at`, outcome). Content-free by construction: there is no content in an issuance call.

### 2.6 What the exchange does not do

- It does not decide what the agent may do with data. That is hometown (purpose masking) and olive (action authorization).
- It does not issue keys without a user key. Machine-identity or Entra-token exchange is a later stage (`NONO_v0.4.1` §8 O2).
- It does not issue onward: an agent key cannot mint another agent key.

---

## 3. Amendment To The Endpoint Detection Contract

`POPEYE_CORRECTIONS_v0.3` §3.1, credential-injection bullet, is amended to read:

> Credential injection: for a person's own tools, the per-user virtual key is injected by `nono-proxy` for allowed gateway traffic. For agent profiles, `nono-proxy` injects a session agent key obtained through the agent key exchange (`POPEYE_v0.4.1` §2); the user key is used only to call the exchange and is never injected into agent traffic.

The policy content (allowed FQDN, blocked provider domains) and the detection event schema are unchanged.

---

## 4. Requirements

| REQ | Requirement | TC | Test criteria | Method |
|---|---|---|---|---|
| REQ-AGT-05 | The exchange issues an agent key only to a `user` caller | TC-AGT-05 | Calling with an agent or application key is refused | CI |
| REQ-AGT-06 | `on_behalf_of` is set from the caller, never the body | TC-AGT-06 | A body `on_behalf_of` naming another user is ignored; the issued key names the caller | CI |
| REQ-AGT-07 | Unknown `agent_id` or unlisted `purpose` is refused | TC-AGT-07 | Exchange with `agent_id=unknown` or `purpose=invented` fails with distinct errors | CI |
| REQ-AGT-08 | TTL is capped and never lengthened | TC-AGT-08 | Request 48 h; granted `expires_at` ≤ 8 h | CI |
| REQ-AGT-09 | Agent keys inherit, and cannot exceed, the caller's class ceiling, tenant and budget | TC-AGT-09 | A user key capped at `internal` mints an agent key that is refused a `regulated-financial` model | CI |
| REQ-AGT-10 | Revocation is idempotent and limited to the minting user key | TC-AGT-10 | Second revocation succeeds; revocation by a different user key fails | CI |
| REQ-AGT-11 | Ledger rows on agent keys carry `key_id` | TC-AGT-11 | Live verifier asserts non-null `key_id` and `principal_type=agent` on Liam traffic | CI (live) |

---

## 5. Open Items

- O1. Whether user keys carry an explicit purpose list today. If not, the intersection rule in §2.2 reduces to vocabulary validation for POC-2, and that is a stated limitation, not a silent one.
- O2. Program TTL cap (8 h proposed). Confirm against the longest expected agent session.
- O3. Where the agent-ID registry lives (proposed: beside the model-approval registry, vendored-vocabulary-checked in the same CI job).

---

## Ratification Record

| Field | Value |
|---|---|
| Decision | **Ratified**, jointly with `NONO_v0.4.1.md` as one seam (agent key minting and injection) |
| Date | 2026-10-19 |
| Ratified by | Oscar Mack (architecture and risk decisions) |
| Scope ratified | §2 (exchange interface, issuance rules, ledger, revocation, issuance events, non-goals), §3 (amendment to the endpoint detection contract), §4 (REQ-AGT-05 to -11) |
| Not ratified here | §5 open items O1 to O3 remain open; the 8 h TTL cap is ratified as the POC-2 value pending O2. The hometown and olive authentication question (`SPEC_ALIGNMENT_LIAM_v0.1.md` G1) is outside this amendment and remains open |
| Effect | `POPEYE_CORRECTIONS_v0.3.md` §3.1 credential-injection bullet is amended as stated in §3. Implementation may start; Liam's end-to-end tests depend on it |
| Change control | Any change to §2.1 request or response fields, §2.2 issuance rules or §2.4 revocation requires a matching change to `NONO_v0.4.1.md` and re-ratification of both |
