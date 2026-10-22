# Popeye v0.4.2 — Agent Key Introspection

Version: 0.4.2
Status: **Ratified 2026-10-19**, jointly with `NONO_v0.4.2.md` (one seam), via `DECISION_agent-key-service-scope.md`. See Ratification Record at the end.
Repository: popeye (`specs/`)
Amends: `POPEYE_v0.4.1.md` (adds §2.7 and REQ-AGT-12 to -19; adds `direct_gateway` to the exchange request).
**Revised 2026-10-19 (pre-ratification)** for gap G5: hometown relays agent model calls on the session key (§2.6).
Audience: popeye maintainer; nono, hometown and olive owners; Liam implementer.
Primary post-read action: implement §2 before Liam's end-to-end tests.

---

## 1. Why

`NONO_v0.4.2` injects the session agent key on hometown and olive as well as the gateway. Those services need to learn, from an authoritative source, who the key acts for and under which purpose. Today only the gateway can read a key's properties. This amendment adds one read-only path for that, and keeps popeye semantics-blind: it reports what a key is; it does not decide what the key may see or do.

---

## 2. Agent Key Introspection (new `POPEYE_v0.4.1` §2.7)

### 2.1 Interface

A popeye-side path on the gateway FQDN that accepts:

- **Authentication:** the calling service's own key, `principal_type=application`, registered as an introspection caller (§2.3).
- **Body:** the presented agent key, as the service received it.

and returns, for an active key:

- `active: true`, `key_id`, `principal_type`, `agent_id`, `on_behalf_of`, `purpose`, `tenant_id`, data-class ceiling, `expires_at`

and, for an expired, revoked, unknown or non-agent key: `active: false` and nothing else. It **never** returns the key secret or any other key.

### 2.2 Rules

| Rule | Enforcement |
|---|---|
| Read-only | Introspection cannot extend, refresh, revoke or mint. It reports state |
| Caller must be a registered service | Unregistered callers, `user` keys and `agent` keys are refused |
| Inactive keys reveal nothing | `active: false` without reason, so a probe learns nothing about which keys once existed |
| Caching | A service may cache a positive result for at most 60 s and never past `expires_at`. Revocation therefore takes effect at services within 60 s; stated, not hidden |
| No onward use | A service that introspects a key may not present it to the exchange; the exchange already refuses non-user callers (REQ-AGT-05) |

### 2.3 Registered introspection callers

POC-2 set: `hometown`, `olive`. The list lives beside the agent-ID registry (`POPEYE_v0.4.1` §5 O3) and is checked in the same CI job. Adding a caller is a program decision, not configuration drift.

### 2.4 Introspection events

Every introspection is recorded (caller, `key_id` when active, result, time). Content-free by construction.

### 2.5 What introspection does not do

- It does not tell hometown which fields a purpose permits, or olive which actions are allowed. Those decisions stay with hometown (`HOMETOWN_v0.4` §4) and olive.
- It does not resolve `on_behalf_of` to directory groups. The calling service does that (`POPEYE_v0.4` §5: "resolve `on_behalf_of` to a directory group" → hometown/olive).

### 2.6 Relayed model calls and `direct_gateway`

hometown makes the model call for an agent's answer (`HOMETOWN_v0.4` role; Liam design v0.3 D5). It makes that call **on the session agent key**, so the ledger attributes it to the agent and its user (REQ-AGT-03), not to hometown's application key.

- **Relay identity.** hometown presents the agent key as the request credential plus its own service identity (its application key in a separate relay header, or mutual TLS where available). popeye validates the relay identity against a registered relay list; POC-2 set: `hometown` only. olive is not a relay.
- **Ledger.** Relayed rows record `relayed_by=hometown` alongside the agent fields.
- **`direct_gateway`.** The exchange request (`POPEYE_v0.4.1` §2.1) gains `direct_gateway` (bool), bound to the key. For `direct_gateway=false`, any gateway call on the key without a valid registered relay identity is refused with a distinct error. For `true`, unrelayed calls are accepted as today.
- **What relay does not change.** The relay cannot change the key's purpose, ceiling, tenant or budget; it can only present the key as minted.

---

## 3. Exposure Statement

Shared with `NONO_v0.4.2` §5. Introspection gives olive an identity answer, not a capability. hometown additionally relays model calls on the key, which is sanctioned and recorded (`relayed_by`). With `direct_gateway=false`, no other holder can use the key at the gateway. Residual risk (a compromised hometown misusing a live key; replay of `direct_gateway=true` keys) is accepted and stated there.

---

## 4. Requirements

| REQ | Requirement | TC | Test criteria | Method |
|---|---|---|---|---|
| REQ-AGT-12 | Introspection returns the key's identity properties for an active agent key and never a secret | TC-AGT-12 | Response for an active key has the listed fields; a sentinel key value never appears in any response or log | CI |
| REQ-AGT-13 | Inactive, unknown or non-agent keys return `active: false` and nothing else | TC-AGT-13 | Expired, revoked, invented and user keys each return the bare inactive response | CI |
| REQ-AGT-14 | Only registered service callers may introspect | TC-AGT-14 | Calls authenticated with an unregistered application key, a user key or an agent key are refused | CI |
| REQ-AGT-15 | Introspection is read-only | TC-AGT-15 | After introspection, the key's `expires_at` and status are unchanged | CI |
| REQ-AGT-16 | Revocation reaches services within the cache bound | TC-AGT-16 | Revoke a key; hometown and olive stubs that cache per §2.2 refuse it within 60 s | CI (stub) |
| REQ-AGT-17 | Relayed model calls are attributed to the agent and record `relayed_by` | TC-AGT-17 | A hometown-relayed call on an agent key yields a ledger row with `principal_type=agent`, the key's `on_behalf_of`, and `relayed_by=hometown` | CI (live) |
| REQ-AGT-18 | A key minted with `direct_gateway=false` refuses unrelayed gateway calls | TC-AGT-18 | Present such a key directly, and with an olive identity as relay; both refused with the distinct error | CI |
| REQ-AGT-19 | Only registered relays are accepted | TC-AGT-19 | An unregistered application key as relay identity is refused | CI |

---

## 5. Olive Requirement (one line, owned by olive)

**Olive accepts the session agent key on its proposal endpoint, validates it through popeye introspection (§2), authorizes against `on_behalf_of`'s entitlements intersected with the agent's, and never forwards the key to any target system.**

---

## Ratification Record

| Field | Value |
|---|---|
| Decision | **Ratified**, jointly with `NONO_v0.4.2.md` as one seam (agent key scope across program services, as revised for gap G5) |
| Date | 2026-10-19 |
| Ratified by | Oscar Mack (architecture and risk decisions), via `DECISION_agent-key-service-scope.md` |
| Scope ratified | §2.1–§2.5 (introspection), §2.6 (relayed model calls, relay registry, `direct_gateway`), §3 (exposure), §4 (REQ-AGT-12 to -19), §5 (olive one-line requirement, owned by olive) |
| Not ratified here | Registered caller and relay list location (`POPEYE_v0.4.1` §5 O3); the relay identity mechanism (separate header or mutual TLS) is popeye's implementation choice; olive's conformance to §5 |
| Effect | Amends the v0.4.1 predecessor as stated in the header. Implementation may start; Liam's end-to-end tests (TC-E2E-01, -05, -07) depend on it and stay `not measured` until it is implemented |
| Change control | Any change requires a matching change to `NONO_v0.4.2.md` and re-ratification of `DECISION_agent-key-service-scope.md` |
