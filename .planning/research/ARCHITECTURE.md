# Architecture Research

**Domain:** Agent-key issuer and introspection service alongside an internal LiteLLM gateway on Azure Container Apps (brownfield Popeye milestone)
**Researched:** 2026-10-22
**Confidence:** MEDIUM overall. Spec-derived boundaries are HIGH. Azure routing is MEDIUM-HIGH (official docs). LiteLLM hook internals are MEDIUM-LOW (they depend on the version and need a spike against the pinned image tag).

---

## 1. The Shape In One Paragraph

Split the work by when it runs. **Issuance-time logic** goes in a new Python issuer Container App: minting, revocation, introspection, the registries, the TTL cap and inheritance. That app is the only holder of the LiteLLM admin credential. **Request-time logic** goes in a LiteLLM `CustomLogger` pre-call hook baked into the gateway image: stamping attribution onto the ledger row, capturing `run_id`, enforcing the purpose/class prohibition, and enforcing `direct_gateway`/relay. The hook reads only what LiteLLM has already loaded for the key (the key metadata) plus static policy rendered by Terraform, so **the issuer is never in the model-call path**. **Observation logic** goes in out-of-band jobs and Azure Monitor: run-cost alerting, detection-to-alert and issuance anomalies. Callers reach both apps on one stable FQDN through a Container Apps environment-level HTTP route config (rule-based routing, GA Nov 2025). It sends `/popeye/*` to the issuer and everything else to LiteLLM.

---

## 2. Standard Architecture

### 2.1 System Overview

```
 Callers (all internal)
 ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌───────────────┐
 │ nono-proxy   │  │ hometown     │  │ olive        │  │ desktop tools │
 │ (user key →  │  │ (app key;    │  │ (app key;    │  │ (user key)    │
 │  exchange;   │  │  introspect; │  │  introspect  │  │               │
 │  agent key → │  │  RELAY on    │  │  only)       │  │               │
 │  model calls)│  │  agent key)  │  │              │  │               │
 └──────┬───────┘  └──────┬───────┘  └──────┬───────┘  └──────┬────────┘
        └─────────────────┴────────┬────────┴─────────────────┘
                                   ▼  https://gateway-azure.ai.twg.internal
 ┌─────────────────────────────────────────────────────────────────────────┐
 │ Container Apps environment (internal LB)  — httpRouteConfig "gateway"   │
 │   /popeye/v1/*  ───────────────────────────┐   /  (everything else) ──┐ │
 ├────────────────────────────────────────────┼──────────────────────────┼─┤
 │  ┌─────────────────────────────────────┐   │  ┌─────────────────────────▼┐│
 │  │ popeye-issuer (NEW, Python/FastAPI) │◄──┘  │ popeye gateway (LiteLLM) ││
 │  │  - agent key exchange / revoke      │      │  + popeye_hooks (NEW)    ││
 │  │  - introspection                    │─────►│    pre-call: stamp attr, ││
 │  │  - registries (agent, callers)      │ admin│    run_id, purpose/class,││
 │  │  - issuance/introspection events    │ API  │    direct_gateway/relay  ││
 │  │  holds: LiteLLM admin credential    │(intra│  holds: master key       ││
 │  └───────┬─────────────────────────────┘ env) └────┬───────────┬────────┘│
 │          │   ┌──────────────────────────────┐      │           │         │
 │          │   │ popeye-monitor (NEW, ACA Job)│      │           │         │
 │          │   │  cron: run-cost, reconcile   │      │           │         │
 │          │   └──────┬───────────────────────┘      │           │         │
 └──────────┼──────────┼──────────────────────────────┼───────────┼─────────┘
            ▼          ▼ (read-only)                  ▼           ▼
 ┌─────────────────────────────────────────────┐ ┌─────────┐ ┌──────────────┐
 │ Postgres Flexible Server (existing, ZR)     │ │ Redis   │ │ Foundry (MI) │
 │  db litellm: VerificationToken, SpendLogs   │ │ (auth   │ └──────────────┘
 │     + VIEW popeye_ledger_v1 (NEW)           │ │  cache, │
 │  db popeye_issuer (NEW): agent_keys,        │ │  limits)│
 │     issuance_events, introspection_events   │ └─────────┘
 └──────────────────┬──────────────────────────┘
                    ▼ ekg_cube_reader (SELECT on view only)
               hometown Cube (ai_token_usage)

 Out-of-band (never in request path):
   popeye-monitor / Read-EndpointDetections ──► Logs Ingestion API (DCR) ──►
   Log Analytics custom tables ──► scheduled-query alerts ──► Teams action group
```

### 2.2 Component Responsibilities

| Component | Status | Owns | Must NOT own | Implementation |
|---|---|---|---|---|
| **LiteLLM gateway** (`modules/gateway-service-azure`) | Modified | Key auth (incl. native expiry, `expired_key` 401), budgets, model allowlist, routing to Foundry, SpendLogs writes | Minting rules, registries, introspection | Pinned LiteLLM image becomes a **derived image** `FROM ghcr.io/berriai/litellm:<pinned>` + `popeye_hooks.py` |
| **popeye_hooks** (in gateway process) | New | Request-time rules: attribution stamping into `spend_logs_metadata`, `run_id` capture, REQ-PUR-07 purpose/class prohibition, REQ-AGT-18/19 relay and `direct_gateway`, stripping the relay header | Any network call to the issuer, prompt inspection, semantic decisions | `CustomLogger.async_pre_call_hook` registered under `litellm_settings.callbacks` |
| **popeye-issuer** | New | Agent key exchange (REQ-AGT-05..11), revocation, introspection (REQ-AGT-12..16), UUID `key_id` (REQ-AGT-20/21), issuance and introspection events, agent-ID/caller registries, TTL cap, inheritance computation | Model-call proxying, ledger writes, budget enforcement (LiteLLM does it), long-lived caching of user-key state | Python 3.12, FastAPI, httpx, psycopg 3. Second Container App in the **same environment**, own UAMI, ≥2 replicas |
| **Issuer store** (`popeye_issuer` database on the existing server) | New | Durable agent-key registry (key_id PK, token hash, minting key hash, agent fields, `direct_gateway`, expiry, revoked_at), append-only event tables | Key secrets (hash only), prompt content | Separate database + role `popeye_issuer`; no grants on the LiteLLM db |
| **Ledger contract view** `popeye_ledger_v1` | New | Stable, flattened attribution columns (`principal_type`, `agent_id`, `on_behalf_of`, `purpose`, `key_id`, `tenant_id`, `run_id`, `relayed_by`) over `LiteLLM_SpendLogs.metadata` | Computing run totals (hometown joins) | SQL view in `sql/`; `ekg_cube_reader` gets SELECT on the view, not on raw JSON paths |
| **Policy bundle** (rendered) | New | One JSON rendered by Terraform from `config/model-approval-registry*.yaml`, `config/agent-registry.yaml` and vendored vocabulary: model→approved class, prohibited purpose/class pairs, relays, introspection callers, agent IDs, TTL cap | Secrets | ADR-002 pattern, extended: delivered as a Container Apps secret/env var to **both** apps. A change means a new revision of both, which is auditable |
| **Routing** (`httpRouteConfig`) | New | Path split on the stable FQDN, custom domain + cert binding | Auth (each app authenticates itself) | `azapi_resource` `Microsoft.App/managedEnvironments/httpRouteConfigs` (no azurerm resource found) |
| **popeye-monitor** | New | Run-cost threshold evaluation over the ledger, agent-key reconciliation (issuer registry vs LiteLLM), pushing content-free summaries to Log Analytics | Blocking anything; it observes only | Container Apps **Job** (cron), same Python codebase as the issuer, different entrypoint, read-only DB role |
| **Detection ingestion** | Modified | `Read-EndpointDetections.ps1` forwards content-free detection records to a Log Analytics custom table | A production fleet pipeline (deferred to Stage 3 by contract §3.3) | Logs Ingestion API + DCR; scheduled-query alert → existing action group |
| **Observability module** | Modified | DCR/DCE, custom tables, new scheduled-query alerts (run cost, detections, issuer 5xx, mint-rate anomaly) | — | `modules/gateway-observability-azure` |
| **ACR + image build** | New | Issuer image, derived gateway image, both pinned by digest/tag | `latest` | ACR with AcrPull for both UAMIs; GitHub Actions build. **Needs an ADR-003** because ADR-002 explicitly deferred an image pipeline |

---

## 3. Where Logic Lives: Gateway Hook vs Issuer vs Out-of-Band

This placement table is the main architectural output. The rule behind it is that **if a check must run on every model call, it goes in the hook and uses only data LiteLLM already has in memory. If it runs at mint, revoke or introspect time, it goes in the issuer. If it aggregates, it runs out-of-band.**

| Requirement | Location | Why there | Data the logic needs |
|---|---|---|---|
| REQ-AGT-01/02 principal shape, no onward delegation | **Issuer** (exchange) + fleet script (user keys) | Issuance-time validation | Caller key metadata via `/key/info` |
| REQ-AGT-04 expired agent key → distinct error | **LiteLLM native** | LiteLLM raises `ProxyErrorTypes.expired_key` with 401 and "Expired Key" text, distinct from invalid-key (verified in `user_api_key_auth.py`, main branch). Auth runs **before** hooks, so a hook cannot intercept it | Key `expires` set via `duration` at mint |
| REQ-AGT-05..10 exchange rules, TTL cap, inheritance, revocation scope | **Issuer** | Needs the admin credential and registries. Spec says the endpoint never holds it | Caller key info, registries, policy bundle |
| REQ-AGT-11/03 ledger rows carry agent fields + `key_id` | **Hook** (authoritative stamp) with key-level `spend_logs_metadata` as the default | Request-supplied `spend_logs_metadata` **wins** over key-level values in LiteLLM's merge ("don't override k-v pair sent by request"). Without a hook overwrite, a client could spoof `on_behalf_of` in the ledger | `user_api_key_dict.metadata` |
| REQ-AGT-12..15 introspection | **Issuer** | Read-only lookup. Must never return secrets | Issuer registry (by sha256 of presented key) + `/key/info` confirmation on positive answers |
| REQ-AGT-16 revocation within 60 s at services | **Issuer** (revoke) + **callers** (cache ≤60 s) | The spec puts the cache bound on callers. Popeye's part is that revocation is immediate at the source of truth | — |
| Revocation effective **at the gateway** | **LiteLLM** (`/key/block` or `/key/delete`) + config | LiteLLM's auth cache is per-worker unless `enable_redis_auth_cache`. `user_api_key_cache_ttl` bounds staleness on replicas that missed the invalidation | `general_settings.user_api_key_cache_ttl` ≤ 30 s (tune) |
| REQ-AGT-17 `relayed_by` on ledger | **Hook** | Per-request fact | Relay header → relay key lookup |
| REQ-AGT-18/19 `direct_gateway=false` refuses unrelayed calls; only registered relays | **Hook** | Per-request. Must be fail-closed | Key metadata `direct_gateway`; relay registry from the policy bundle; relay app key resolved via LiteLLM's own key cache |
| REQ-AGT-20/21 UUID `key_id`, byte-identical everywhere | **Issuer** generates (`uuid4`, or `uuid7` if Python ≥3.14 or a lib is used), writes it to key metadata + `key_alias`. **Hook** copies it verbatim into the ledger | One generator, one canonical string, no reformatting downstream | — |
| REQ-PUR-06 purpose in vocabulary at issuance | **Issuer** (agent keys) + fleet script (user keys) | Issuance-time | Vendored vocabulary in the policy bundle |
| REQ-PUR-07 purpose/class prohibition at request time | **Hook** (enforce, 403 distinct code) **and** issuer (narrow `models` at mint, defence in depth) | The spec says "request time". Also covers user keys, which the issuer never touches | Key metadata `purpose`; model→approved-class map in the policy bundle |
| REQ-RUN-01 `run_id` recorded | **Hook** copies the validated `metadata.run_id` into the stamped `spend_logs_metadata` | The client supplies it. The hook normalizes it and size-limits it | Request body metadata |
| REQ-RUN-02 run-cost alert | **popeye-monitor job** → Log Analytics → scheduled-query alert | v0.4 §4: "popeye does not compute run totals", and the ledger is the single source of truth. An aggregate in the request path would violate "observation never in request path" | Read-only ledger view |
| REQ-DCE-07 reject non-UUID `tenant_id` | Fleet script + issuer (inherits it, revalidates) | Issuance-time | — |
| REQ-END-05 detection reaches alerting | **Detection ingestion script** → DCR → alert | POC-grade transport is sanctioned (contract §3.3) | JSONL file |
| Issuance events (REQ-AGT §2.5), introspection events (§2.4) | **Issuer** (Postgres append-only, same transaction as the registry update) + structured log line for alerting | Durable and queryable. Logs alone are not a system of record | — |

**Explicitly rejected placements:**
- **LiteLLM `custom_auth`** for relay/`direct_gateway`. Combining custom auth with LiteLLM virtual keys (`custom_auth_settings.mode: auto`) **requires an Enterprise license** (LiteLLM custom-auth docs). Pure custom auth would replace virtual-key auth and budgets. Use the OSS `CustomLogger` pre-call hook instead.
- **Hook calling the issuer per request** (e.g. to check revocation or relay status). This puts a second service in the model-call path, doubles the failure surface, and adds latency to the Stage 1 latency baseline. Everything the hook needs is either in key metadata (cached by LiteLLM) or in the static policy bundle.
- **Issuer as a forward proxy in front of LiteLLM for model calls.** This turns the issuer into the gateway and violates the thin-wrapper decision (D-2 Option B).

---

## 4. Reaching the Issuer on the Gateway FQDN

**Constraint:** v0.4.1 §2.1 and v0.4.2 §2.1 say "reachable on the gateway FQDN". nono's endpoint policy allows exactly one FQDN, so a separate issuer hostname would need a nono policy change and re-ratification (change control in both specs). Same-FQDN is therefore a hard requirement, not a preference.

### Options

| Option | How | Verdict |
|---|---|---|
| **A. ACA rule-based routing (`httpRouteConfig`)** | Environment-level route config with a custom domain `gateway-azure.ai.twg.internal`. Rules: `pathSeparatedPrefix: /popeye` → issuer, `prefix: /` → gateway. GA Nov 2025 | **Recommended** |
| B. Reverse-proxy sidecar in the gateway app | nginx/Envoy container as the ingress target. It proxies `/popeye/*` to the issuer app and the rest to `localhost:4000` | Fallback if A is blocked in the internal env |
| C. LiteLLM `pass_through_endpoints` → issuer | LiteLLM forwards `/popeye/*` to the issuer | Rejected. It couples issuer availability to LiteLLM config and auth semantics, and pass-through auth features may be Enterprise-gated (unverified) |
| D. Internal Application Gateway | L7 path routing in front of the ACA env | Rejected for this milestone. Cost, another subnet, operational surface. Revisit if WAF or mTLS termination becomes required |
| E. Separate issuer FQDN | `issuer-azure.ai.twg.internal` | Rejected. Breaks the ratified "gateway FQDN" wording and the nono allowlist |

### Recommended design (Option A)

```hcl
# modules/gateway-routing-azure/main.tf  (sketch; verify API version and schema)
resource "azapi_resource" "gateway_routes" {
  type      = "Microsoft.App/managedEnvironments/httpRouteConfigs@2025-02-02-preview"
  name      = "gateway"
  parent_id = var.container_app_environment_id
  body = {
    properties = {
      customDomains = [{
        name          = var.stable_fqdn          # gateway-azure.ai.twg.internal
        bindingType   = "SniEnabled"
        certificateId = var.environment_certificate_id   # private-CA cert
      }]
      rules = [
        { description = "popeye issuer (exchange, revoke, introspect)"
          routes  = [{ match = { pathSeparatedPrefix = "/popeye" } }]   # no rewrite
          targets = [{ containerApp = var.issuer_app_name }] },
        { description = "LiteLLM gateway (everything else)"
          routes  = [{ match = { prefix = "/" } }]
          targets = [{ containerApp = var.gateway_app_name }] },
      ]
    }
  }
}
```

**Path namespace:** `/popeye/v1/agent-keys` (POST mint), `/popeye/v1/agent-keys/{key_id}/revoke` (POST), `/popeye/v1/introspect` (POST, key in the body, never in the URL), `/popeye/healthz`. Keep the issuer's FastAPI routes **with** the `/popeye` prefix (no `prefixRewrite`) so app-internal paths and external paths are the same. That helps logs and tests. `/popeye` does not collide with any LiteLLM route namespace (`/v1/*`, `/chat/*`, `/key/*`, `/user/*`, `/team/*`, `/health/*`, `/ui`). Rule order matters: the specific rule goes first (Microsoft docs).

**Coupled decisions (important for roadmap):**
1. **The stable DNS decision and the route config are one piece of work.** ACA Envoy routes on the Host header. A `gateway-azure.ai.twg.internal` A/CNAME record does nothing until that hostname is bound as a custom domain, on the route config (with route-based routing) rather than on the gateway app. Microsoft's guidance: "Domains are only bound to one app, route, or environment." Binding needs a TLS cert for a private name, which means an internal-CA cert uploaded as an environment certificate, plus the A record pointing at the environment's static ILB IP. The MVP "stable DNS ownership" item should therefore produce the route config. Today it would only produce a DNS record.
2. **Internal-environment behaviour is not documented.** Microsoft's rule-based-routing docs discuss public exposure. They don't say whether route configs work identically on `internal_load_balancer_enabled = true` environments, or how the custom-domain ownership TXT (`asuid`) verification behaves for a private zone. **Spike this first.** If it fails, fall back to Option B (sidecar). B keeps the same external contract, so callers don't change.
3. **Security note from Microsoft docs.** Route targets ignore the app's own `external: false` and are reachable via the route FQDN. In an internal-LB environment that FQDN is still private, so this is not public exposure. It does mean anyone with `httpRouteConfigs/write` on the environment can expose any app in it, so restrict that RBAC.
4. **Optional hardening (cheap with Option A).** Instead of `prefix: /` → gateway, route only the inference and health paths to the gateway (`/v1`, `/chat`, `/completions`, `/embeddings`, `/models`, `/health/liveliness`). LiteLLM admin routes (`/key/*`, `/user/*`, `/ui`) then become unreachable on the stable FQDN. The issuer reaches them via the gateway app's internal name (`http://<gateway-app>`), which is not routed through the config. **Caveat:** `provision-desktop-keys.ps1` currently calls `/key/generate` on the gateway, so it would need the internal app FQDN or a jump path. Decide this in the routing phase.

---

## 5. Data Flows

### Flow 1: Agent key exchange (mint)
```
nono-proxy ──POST /popeye/v1/agent-keys {agent_id, purpose, ttl_seconds, direct_gateway}
           Authorization: Bearer <user key>
   → route config → issuer
issuer:
 1. resolve caller: GET http://<gateway-app>/key/info?key=<user key>  (admin cred, server-side)
    reject if not found / blocked / expired / metadata.principal_type != "user"   (REQ-AGT-05)
 2. validate agent_id ∈ agent registry; purpose ∈ vocabulary (∩ caller purposes if any) (AGT-07, PUR-06)
 3. compute: on_behalf_of = caller principal (body value ignored)                  (AGT-06)
            expires = min(ttl, 8h, caller key expiry)                                (AGT-08)
            models  = caller.models minus purpose-prohibited models                  (AGT-09, PUR-07)
            inherit tenant_id, data_class, user_id, team_id (budget via user/team)   (AGT-09)
 4. key_id = uuid4() lowercase; INSERT agent_keys(status='pending', key_id, minted_by_hash, ...)
 5. POST http://<gateway-app>/key/generate {duration, models, user_id, team_id, key_alias=key_id,
         metadata:{principal_type:"agent", agent_id, on_behalf_of, purpose, key_id, tenant_id,
                   data_class, direct_gateway, minted_by_key_id, spend_logs_metadata:{...}}}
 6. UPDATE agent_keys SET status='active', token_hash=<sha256>, expires_at; INSERT issuance_event
 7. 201 {key, key_id, expires_at, agent_id, purpose, on_behalf_of, principal_type:"agent"}
    (secret appears ONLY in this response body; never logged)
```
Failure between steps 5 and 6 leaves an orphan LiteLLM key. The monitor's reconciliation finds it by `key_alias` (`= key_id`) and blocks it.

### Flow 2: Direct agent model call (`direct_gateway=true`)
```
nono-proxy → /v1/chat/completions (agent key, metadata.run_id)
 LiteLLM auth (cache → DB): valid, not expired/blocked, model in key.models, budget OK
 popeye_hooks.async_pre_call_hook:
   km = user_api_key_dict.metadata
   if km.purpose in PROHIBITED and class(model) ≥ regulated-financial → 403 purpose_class_prohibited
   if km.principal_type=="agent" and not km.direct_gateway → require relay (Flow 3) else 403 relay_required
   data.metadata.spend_logs_metadata = {principal_type, agent_id, on_behalf_of, purpose, key_id,
                                        tenant_id, run_id(validated), relayed_by:null}   # overwrite
 → Foundry (MI) → response → SpendLogs row (metadata JSON) → popeye_ledger_v1 → hometown
```

### Flow 3: Relayed call (hometown, `direct_gateway=false`)
```
hometown → /v1/chat/completions
   Authorization: Bearer <agent key>        X-Popeye-Relay-Key: <hometown app key>
 LiteLLM auth on the agent key (as Flow 2)
 hook: relay_key = header; hash → resolve via LiteLLM key cache/DB (internal helper)
       require: active, principal_type=="application", metadata.service_name ∈ RELAYS (POC: hometown)
       else 403 relay_not_registered (AGT-19)
       strip header from data before the provider call; stamp relayed_by="hometown"     (AGT-17)
```
Do **not** carry the relay credential in any header LiteLLM already treats as an API key (`Authorization`, `api-key`, `x-api-key`, `x-litellm-api-key`, `Ocp-Apim-Subscription-Key`, `x-goog-api-key`), or LiteLLM may authenticate with the wrong key. Ensure `forward_client_headers_to_llm_api` stays off so `x-` headers never reach Foundry.

### Flow 4: Introspection
```
hometown|olive → POST /popeye/v1/introspect {token:<agent key>}   Authorization: Bearer <app key>
issuer: resolve caller via /key/info → principal_type=="application" ∧ service_name ∈ CALLERS else 403 (AGT-14)
        h = sha256(token) → SELECT agent_keys WHERE token_hash=h
        active iff row ∧ status='active' ∧ expires_at>now ∧ (/key/info confirms not blocked)
        active  → 200 {active:true, key_id, principal_type, agent_id, on_behalf_of, purpose,
                       tenant_id, data_class, expires_at}
        else    → 200 {active:false}                            (AGT-13: no reason, no timing oracle)
        INSERT introspection_event(caller, key_id|null, result, ts)  (read-only w.r.t. key state: AGT-15)
callers cache positive answers ≤ min(60 s, expires_at)       (AGT-16, their responsibility)
```

### Flow 5: Revocation
```
nono-proxy → POST /popeye/v1/agent-keys/{key_id}/revoke   Bearer <user key>
issuer: resolve caller; row.minted_by_hash == sha256(caller key) else 403  (AGT-10)
        already revoked/expired → 200 (idempotent)
        POST /key/block {key: token_hash}  (keep the row, so key_id is never reusable and introspection stays bare-inactive)
        UPDATE status='revoked'; INSERT issuance_event(outcome='revoked')
```
Prefer **block** over **delete**. A deleted LiteLLM row loses the evidence trail, and with block there's no question of whether a `key_alias` could be reissued.

### Flow 6: Run-cost alert (REQ-RUN-02)
```
popeye-monitor (cron, e.g. every 5 min) → SELECT run_id, sum(spend), count(*) FROM popeye_ledger_v1
   WHERE start_time > now()-window GROUP BY run_id HAVING sum(spend) > threshold
 → Logs Ingestion API (DCR) → PopeyeRunCost_CL → scheduled-query alert → Teams action group
```
The threshold lives in tfvars, and the alert rule is Terraform. The job pushes content-free rows (run_id, on_behalf_of, agent_id, spend, calls).

### Flow 7: Detection → alert (REQ-END-05)
```
nono JSONL (forwarded, manual OK per contract §3.3) → Read-EndpointDetections.ps1 (validate, content-free)
 → Logs Ingestion API → PopeyeEndpointDetections_CL → scheduled-query alert (count>0) → Teams
```

### Flow 8: Policy delivery
```
config/model-approval-registry.yaml + config/agent-registry.yaml + config/vendored/vocabulary.yaml
  → CI conformance (existing job, extended)
  → Terraform yamldecode → local.popeye_policy_json
  → Container Apps secret on gateway (hook) AND issuer → new revisions of both
```

---

## 6. Key Metadata Contract (the seam between issuer, hook and ledger)

Define this **first**. It is what both the issuer writes and the hook reads. Put it in `contracts/schemas/agent-key-metadata-v0.1.schema.json`.

| Field (LiteLLM key `metadata`) | Writer | Reader | Notes |
|---|---|---|---|
| `principal_type` | issuer (agent), fleet script (user), service-key script (application) | issuer, hook | **Existing user keys lack it.** They need a backfill, or the exchange will refuse all of them |
| `agent_id`, `on_behalf_of`, `purpose` | issuer | hook, introspection | |
| `key_id` | issuer | hook → ledger; introspection | Also `key_alias` (LiteLLM-enforced uniqueness, used for reconciliation) |
| `tenant_id`, `data_class` | fleet script; inherited by issuer | hook, introspection | UUID validated (REQ-DCE-07) |
| `direct_gateway` | issuer | hook | bool. Default `true` only if the spec allows. The safe default is the caller's explicit value, required |
| `service_name` | service-key script | issuer (callers), hook (relays) | Only on `application` keys |
| `minted_by_key_id` | issuer | issuer | Revocation scope (also kept in the issuer DB as a hash) |
| `spend_logs_metadata.*` | issuer (defaults) | LiteLLM merge | **The hook overwrites this per request.** Key-level values alone are spoofable |

The ledger contract (`popeye_ledger_v1` columns) is the hometown hand-off artifact. Version it, and treat changes like contract changes.

---

## 7. Recommended Project Structure (additions)

```
popeye/
├── services/
│   └── issuer/                      # NEW: first runtime code in the repo
│       ├── pyproject.toml           # pinned deps; uv/pip-tools lock
│       ├── Dockerfile               # python:3.12-slim, non-root, no shell needed
│       ├── popeye_issuer/
│       │   ├── app.py               # FastAPI app; routes mounted under /popeye
│       │   ├── routes/              # exchange.py, revoke.py, introspect.py, health.py
│       │   ├── litellm_admin.py     # ONLY module that touches the admin credential
│       │   ├── rules.py             # pure functions: TTL cap, inheritance, purpose checks
│       │   ├── policy.py            # loads rendered policy bundle (env/secret)
│       │   ├── store.py             # psycopg; agent_keys + events
│       │   ├── redaction.py         # log/exception redaction; sentinel-tested
│       │   └── monitor/             # entrypoint for popeye-monitor job (run-cost, reconcile)
│       ├── migrations/              # SQL for popeye_issuer db
│       └── tests/                   # unit (rules), contract (fixtures), sentinel, live markers
├── gateway/
│   ├── Dockerfile                   # FROM ghcr.io/berriai/litellm:${LITELLM_TAG}; COPY hooks
│   └── hooks/
│       ├── popeye_hooks.py          # proxy_handler_instance = PopeyeHooks()
│       └── tests/                   # hook unit tests with fake UserAPIKeyAuth/data
├── config/
│   └── agent-registry.example.yaml  # NEW: agent_ids, introspection_callers, relays
├── contracts/schemas/
│   ├── agent-key-metadata-v0.1.schema.json
│   ├── agent-key-exchange-v0.1.schema.json      # request/response
│   └── introspection-v0.1.schema.json
├── sql/
│   ├── popeye_ledger_v1.sql         # view + ekg_cube_reader grant
│   └── popeye_issuer_bootstrap.sql  # db + role
├── modules/
│   ├── gateway-service-azure/       # MODIFIED: derived image var, policy secret, hook config
│   ├── issuer-service-azure/        # NEW: UAMI, KV refs, container app, probes, ≥2 replicas
│   ├── gateway-routing-azure/       # NEW: azapi httpRouteConfig + env certificate
│   ├── container-registry-azure/    # NEW: ACR + AcrPull role assignments
│   └── gateway-observability-azure/ # MODIFIED: DCE/DCR, custom tables, query alerts, monitor job?
└── specs/ADR-003-images-and-hooks.md   # NEW decision record
```

**Structure rationale:**
- **`litellm_admin.py` is a single choke point.** Code review can check that the admin credential is touched in exactly one file, and the sentinel test targets it.
- **`rules.py` is pure.** Every REQ-AGT-05..10 TC becomes a fast unit test with no network. Live tests only verify wiring.
- **The monitor shares the issuer codebase.** One image and one dependency lock. It runs as a separate ACA Job with its own read-only identity.
- **The gateway hook is separate from the issuer.** It ships in a different process and image, and is versioned with the LiteLLM tag.

---

## 8. Architectural Patterns

### Pattern 1: Authoritative server-side attribution stamp
**What:** The pre-call hook overwrites `spend_logs_metadata` with values from the authenticated key's metadata. It merges in only the client-supplied fields that are allowed (`run_id`).
**Why:** LiteLLM merges key-level `spend_logs_metadata` *under* request-level values ("request values win"). It also strips client metadata keys beginning with `user_api_key_`, but not arbitrary keys like `on_behalf_of`.
**Trade-off:** It couples to LiteLLM's metadata variable name. Some routes use `litellm_metadata` instead of `metadata`, so handle both.

```python
# gateway/hooks/popeye_hooks.py  (sketch: verify field names against the pinned tag)
from fastapi import HTTPException
from litellm.integrations.custom_logger import CustomLogger

ATTR = ("principal_type", "agent_id", "on_behalf_of", "purpose", "key_id", "tenant_id")

class PopeyeHooks(CustomLogger):
    async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):
        km = user_api_key_dict.metadata or {}
        model = data.get("model")
        if POLICY.purpose_class_prohibited(km.get("purpose"), model):
            raise HTTPException(403, {"error": "purpose_class_prohibited"})      # REQ-PUR-07
        relayed_by = await self._check_relay(km, data)                           # REQ-AGT-17..19
        mkey = "litellm_metadata" if "litellm_metadata" in data else "metadata"
        md = data.setdefault(mkey, {})
        run_id = _valid_run_id(md.get("run_id") or (md.get("spend_logs_metadata") or {}).get("run_id"))
        md["spend_logs_metadata"] = {**{k: km.get(k) for k in ATTR},
                                     "run_id": run_id, "relayed_by": relayed_by}
        return data

proxy_handler_instance = PopeyeHooks()   # instance, not class (docs: class ref fails load)
```

### Pattern 2: Issuer as the sole holder of the admin credential (thin wrapper, D-2 Option B)
**What:** The issuer's UAMI is the only identity other than the gateway's with `Key Vault Secrets User` on the admin secret. Ideally the issuer uses a **dedicated admin-capable credential** (separately revocable) rather than the gateway master key. Feasibility of a non-master proxy-admin key is unverified, so start with the master key via a KV reference and record the upgrade path.
**When:** Always. Fleet scripts that mint user keys also hold it today (operator-run). Note that as a separate, operator-only path.

### Pattern 3: Reserve-then-mint saga with UUID-as-alias
**What:** Insert the `key_id` row first (PK uniqueness gives never-reused), mint with `key_alias=key_id`, then activate. The reconciliation job closes the gap for orphans.
**Trade-off:** One extra write per mint. Mint volume is per-session, so this is negligible.

### Pattern 4: Policy-as-data rendered once, consumed twice
**What:** One Terraform-rendered policy bundle feeds both the hook and the issuer. CI checks the source YAML against the vendored vocabulary.
**Why:** The prohibition rule and model classes must agree between issuance-time narrowing and request-time enforcement. Two copies will drift.

### Pattern 5: Bare-inactive introspection
**What:** Every non-active path returns an identical `{"active": false}`, same status code, and similar latency. Do the DB lookup even for malformed tokens.
**Why:** REQ-AGT-13 says "a probe learns nothing".

---

## 9. Build Order (dependency-driven)

```
[0] MVP smoke (ledger row) ─────────────┐
[1] Stable FQDN + custom domain + cert ─┼─► [4] Routing (httpRouteConfig) ──┐
[2] ACR + image pipeline (ADR-003) ─────┼─► [3] Gateway hook + derived image ┤
[2b] Key metadata contract + registries ┘        + ledger view               ├─► [6] Introspection + relay
     + vocab-correct registry (DCE-05/06)        ▲                            │        + service app keys
     + fleet script w/ principal_type/tenant     │                            │
                                     [5] Issuer: exchange, revoke, events ────┘
                                                                         ──► [7] Alerting: run-cost, detections,
                                                                                  issuer health; runbooks
```

| Order | Phase content | Depends on | Unblocks | Why here |
|---|---|---|---|---|
| 1 | **MVP closure:** smoke completion → attributed ledger row; stable DNS decision *taken together with* custom-domain/cert/route-config feasibility spike | existing stack | everything | Proves the ledger path all later attribution relies on. The DNS decision decides the routing option |
| 2 | **Foundations:** registry vocab corrections (DCE-05/06), `config/agent-registry.yaml` + CI, key metadata contract schema, fleet key script emitting `principal_type=user` + UUID `tenant_id` (DCE-07) + budget at user/team level, backfill of existing user keys, ACR + image build + ADR-003 | 1 | 3, 5 | The issuer refuses non-`user` callers, so user keys must carry `principal_type` first. Budget inheritance works only if the budget sits at user/team level. Images are needed by both 3 and 5 |
| 3 | **Gateway hook + ledger contract:** spike on the pinned tag (metadata reaches SpendLogs, header access, relay key lookup), hook (stamp, run_id, purpose/class), derived image, `popeye_ledger_v1`, hometown hand-off | 2 | 5 (live tests), 6 | Highest technical uncertainty. Its findings fix the metadata contract the issuer writes. Testable with admin-minted agent keys before the issuer exists |
| 4 | **Routing on the gateway FQDN:** azapi route config, env certificate, DNS A record, optional admin-path hardening | 1 (spike result) | 5 external reachability | Can run in parallel with 3 |
| 5 | **Issuer core:** exchange, revocation, issuance events, issuer DB, `issuer-service-azure` module, sentinel/redaction tests, TC-AGT-05..11, 20 | 2, 3, 4 | nono `AgentSessionRecord`, Liam E2E | **The nono critical path.** Start it as soon as 2 is done. Parallelising its pure `rules.py` with 3 is safe |
| 6 | **Introspection + relay:** introspect endpoint, application keys for hometown/olive (`service_name`), relay enforcement in the hook (`direct_gateway`), `relayed_by`, cache-bound stub test (TC-AGT-16), TC-AGT-21 five-surface trace | 5 | Liam E2E-01/05/07 | Needs agent keys minted with `direct_gateway` and registered service keys |
| 7 | **Out-of-band alerting:** DCR/custom tables, monitor job (run cost, reconciliation), detection ingestion → alert, issuer alerts; runbooks updated for the issuer (break-glass revocation of all agent keys) | 3 (run_id in ledger), 5 | REQ-RUN-02, REQ-END-05 | Observes only. Can start once `run_id` lands. Detection alerting depends only on 1 and could move earlier |

Fleet automation, Intune and the DLP evaluation are not on this graph's critical path except for the `principal_type`/tenant/budget change to `provision-desktop-keys.ps1`, which is a **hard prerequisite of phase 5**.

---

## 10. Anti-Patterns

### Anti-Pattern 1: Trusting key-level `spend_logs_metadata` for attribution
**What people do:** Put `on_behalf_of` in the key's `spend_logs_metadata` at mint and stop there.
**Why it's wrong:** Request-level values override key-level ones in LiteLLM's merge. An agent could write any `on_behalf_of` into the ledger.
**Do this instead:** Have the hook overwrite the attribution fields on every request (Pattern 1). Add a test that sends a spoofed `on_behalf_of` and asserts the ledger shows the key's value.

### Anti-Pattern 2: Putting the issuer in the model-call path
**What people do:** Have the hook call `/popeye/v1/introspect` or an issuer "check" endpoint for relay or revocation.
**Why it's wrong:** The issuer's availability becomes gateway availability, every call gains latency, and Stage 1 baselines become invalid.
**Do this instead:** Put everything the hook needs in key metadata or the static policy bundle. Revocation uses LiteLLM's native block plus a cache TTL.

### Anti-Pattern 3: Delivering hook code as a Container Apps secret
**What people do:** Extend ADR-002 to write `popeye_hooks.py` from an env secret to `/tmp` next to the config. It technically works, because LiteLLM resolves module paths relative to the config file.
**Why it's wrong:** Executable code lives in Terraform state. It isn't scanned or unit-tested as an artifact, and the "config is non-secret metadata" rationale of ADR-002 no longer holds.
**Do this instead:** Use a derived image pinned to the same LiteLLM tag. The ACR is needed for the issuer anyway. Keep the `latest`-rejection validation on the base tag variable.

### Anti-Pattern 4: Relay credential in an auth header LiteLLM recognises
**Why it's wrong:** LiteLLM accepts keys from several headers. Mixing the agent key and the relay key across them makes "which key authenticated" ambiguous.
**Do this instead:** Use the dedicated `X-Popeye-Relay-Key`. The hook strips it, and header forwarding stays off.

### Anti-Pattern 5: Deleting revoked keys
**Why it's wrong:** You lose the evidence trail, and it becomes unclear whether a `key_id`/alias could be reused (REQ-AGT-20 says never reused).
**Do this instead:** Block the key in LiteLLM and keep the status row in the issuer DB.

### Anti-Pattern 6: Computing run totals in the hook or issuer
**Why it's wrong:** v0.4 §4 says cost computed in two places will disagree.
**Do this instead:** Have the monitor job aggregate ledger rows out-of-band.

---

## 11. Scaling Considerations

| Scale | Adjustments |
|---|---|
| POC-2 (tens of users, a few agents, hometown/olive) | 2 replicas each. Mint and introspect volume is trivial. Issuer resolves callers via `/key/info` uncached |
| Fleet (hundreds–low thousands of users, per-run agent keys) | The **LiteLLM VerificationToken table grows with per-run keys**. Add a monitor task that hard-deletes LiteLLM rows of long-expired agent keys after the evidence window (the issuer row keeps `key_id` reserved). Introspection: callers' 60 s cache bounds load |
| Multi-region (Stage 3) | Issuer is regional like the gateway. `key_id` is a UUID, so it's globally unique without coordination. The registry stays per region unless cross-region introspection becomes a requirement (not in spec) |

**First bottleneck:** LiteLLM auth cache coherence across replicas (revocation latency), not throughput. Set `user_api_key_cache_ttl` deliberately, and consider `enable_redis_auth_cache` once Redis channel ACLs are confirmed.

---

## 12. Integration Points

### External / cross-repo

| Party | Integration | Notes |
|---|---|---|
| nono | `POST /popeye/v1/agent-keys`, revoke. Receives `key_id` (16-byte UUID) | Contract fields frozen by ratification. Any change requires NONO re-ratification |
| hometown | Introspect (app key). Relay on agent key + `X-Popeye-Relay-Key`. Reads `popeye_ledger_v1` | The relay header name and the ledger view are new hand-off artifacts. Publish them in `contracts/` |
| olive | Introspect only. Never a relay | Must not be in the relay list (TC-AGT-18 checks olive as relay → refused) |
| Foundry | Unchanged (MI + RBAC) | |

### Internal boundaries

| Boundary | Communication | Notes |
|---|---|---|
| issuer → gateway admin API | HTTP on intra-environment app name (`http://<gateway-app>`), master/admin key from KV | Not via the route config. Admin paths can be closed on the stable FQDN |
| hook → policy | In-process, loaded at startup from env secret | Change = new revision |
| hook → relay key resolution | LiteLLM internal key lookup (cache → Prisma) | Internal API, version-coupled. Pin and regression-test on every LiteLLM upgrade |
| issuer → Postgres | `popeye_issuer` db, own role. Prefer Entra token auth for the UAMI if the server has Entra auth enabled (currently password-only; unverified) | No grants on the `litellm` db except via the admin API |
| monitor → Postgres | Read-only role on `popeye_ledger_v1` + `popeye_issuer` | |
| monitor/scripts → Log Analytics | Logs Ingestion API via DCE/DCR with UAMI (`Monitoring Metrics Publisher` on the DCR) | Content-free rows only |

---

## 13. Open Questions / Spikes (flag for phase research)

1. **LiteLLM pinned-tag behaviour (Phase 3 spike, highest priority).** Does `spend_logs_metadata` set in `async_pre_call_hook` land in `LiteLLM_SpendLogs.metadata`? Which metadata key (`metadata` vs `litellm_metadata`) is used on `/v1/chat/completions`? Are raw request headers readable in the hook? `data["proxy_server_request"]["headers"]` is a *logging-safe, redacted* copy on current main, and raw headers sit in `data["secret_fields"]` as `RedactedDict`. What is the supported way to resolve a second key (the relay key) inside the hook? Confidence: LOW until tested.
2. **ACA route config on an internal-LB environment with a private custom domain and internal-CA cert (Phase 1/4 spike).** Docs don't cover it. Fallback: sidecar proxy.
3. **Budget inheritance mechanics.** Agent keys share the caller's `user_id`/`team_id`, so user/team budgets apply. Key-level `max_budget` on the user key does **not** cover spend on sibling agent keys. Confirm how fleet keys carry budget today, and decide user-level versus key-level budgeting before phase 5.
4. **Dedicated admin credential.** Can a non-master virtual key (proxy-admin role) call `/key/generate`, `/key/block` and `/key/info` in OSS? If yes, use it so issuer compromise ≠ master-key compromise.
5. **Non-admin `/key/info` on own key.** If supported, the issuer could resolve callers with their own key and avoid the admin credential for auth. Unverified.
6. **Revocation propagation across gateway replicas.** Measure the time from `/key/block` to refusal on all replicas. Choose `user_api_key_cache_ttl` / `enable_redis_auth_cache` accordingly. Azure Managed Redis channel ACLs are untested.
7. **`direct_gateway` default** when nono omits it. The spec adds it as a bool bound to the key but doesn't state a default. Recommend required, with no default. Confirm with nono.

---

## Sources

- Repo specs (HIGH): `specs/POPEYE_v0.4.md`, `POPEYE_v0.4.1.md`, `POPEYE_v0.4.2.md`, `POPEYE_v0.4.3.md`, `SESSION_CREDENTIAL_ISSUER_v0.1.md`, `ADR-002-gateway-config-delivery.md`, `ENDPOINT_DETECTION_CONTRACT_v0.1.md` §3.3; `envs/azure-eastus2/main.tf`; `modules/gateway-service-azure/main.tf`; `modules/gateway-observability-azure/main.tf`; `sql/ai_usage_grants.sql`
- [Use rule-based routing in Azure Container Apps (Microsoft Learn, updated 2026-08-05)](https://learn.microsoft.com/azure/container-apps/rule-based-routing): environment-level route configs, match types, rule order, internal-ingress exposure warning (HIGH)
- [Rule-based routing with custom domain (Microsoft Learn)](https://learn.microsoft.com/en-us/azure/container-apps/rule-based-routing-custom-domain): domain binds to one app/route/env, cert/asuid requirements (MEDIUM: via search summary)
- [GA announcement AZ512850](https://mc.merill.net/message/AZ512850): rule-based routing GA Nov 2025 (MEDIUM)
- [httpRouteConfigs ARM reference](https://learn.microsoft.com/en-us/azure/templates/microsoft.app/managedenvironments/httprouteconfigs): latest API 2025-02-02-preview; no azurerm resource found, so use azapi (MEDIUM)
- [LiteLLM call hooks](https://docs.litellm.ai/docs/proxy/call_hooks): `async_pre_call_hook` signature, HTTPException rejection, instance (not class) registration (HIGH)
- [LiteLLM custom auth](https://docs.litellm.ai/docs/proxy/custom_auth): custom auth + virtual keys (`mode: auto`) requires Enterprise (HIGH)
- [LiteLLM cost tracking / spend_logs_metadata](https://docs.litellm.ai/docs/proxy/cost_tracking): key/request/header sources (HIGH)
- [LiteLLM virtual keys](https://docs.litellm.ai/docs/proxy/virtual_keys): `/key/generate` params (`duration`, `key_alias`, `metadata`, `models`), `/key/block` (HIGH)
- [litellm_pre_call_utils.py (main)](https://raw.githubusercontent.com/BerriAI/litellm/main/litellm/proxy/litellm_pre_call_utils.py): request-wins merge, `proxy_server_request` redacted headers, untrusted metadata stripping (MEDIUM: main branch, not the pinned tag)
- [user_api_key_auth.py (main)](https://raw.githubusercontent.com/BerriAI/litellm/main/litellm/proxy/auth/user_api_key_auth.py): `expired_key` 401 distinct error; blocked-key message (MEDIUM)
- [LiteLLM caching controls](https://docs.litellm.ai/docs/proxy/caching_controls): per-worker auth cache, `enable_redis_auth_cache`, `user_api_key_cache_ttl` (LOW-MEDIUM: search summary)

---
*Architecture research for: Popeye agent-key issuer/introspection alongside LiteLLM on Azure Container Apps*
*Researched: 2026-10-22*
