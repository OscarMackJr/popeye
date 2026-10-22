# Popeye Corrections And Contracts v0.3

Version: 0.3
Status: Draft — closes popeye's share of cross-repo findings X1, X5, X7, and the carried fallback-chain item
Repository: popeye. Audience: popeye team; nono maintainer for section 3.
Primary post-read action: land P-1 and P-2 before the POC; make the P-4 decision in writing either way.

## 1. P-1 — Registry Conformance To The Program Taxonomy (X1, enforcement half)

The model-approval registry currently declares its own four-class vocabulary (`public`, `internal`, `confidential`, `regulated`). Per `fiskroad/specs/PROGRAM_SHARED_VOCABULARY_v0.3`, the registry declares no vocabulary of its own.

Changes:

1. Replace the registry's `data_classes` block with the five program class names, exactly: `public`, `internal`, `confidential-personal`, `regulated-financial`, `regulated-identifier`.
2. Re-key existing entries: `twg-foundry` stays `internal`; the example regulated approval becomes `regulated-financial`.
3. **Structural rule:** registry validation rejects any model whose `approved_max_data_class` is `regulated-identifier`. This is the class that exists to be unapprovable — data of this class never enters a prompt; tokenized references (Bluto) are the pattern. The rule lives in `Get-ModelAllowlist.ps1` validation *and* in CI, so a hand-edited registry cannot reintroduce it.
4. Team `default_data_class` values re-key to program names (`regulated-apps` → `regulated-financial` unless the team genuinely handles identifier-class data, in which case its features need redesign, not approval).
5. CI compares the registry's class names against fiskroad's `contracts/vocabulary.yaml` (vendored with a recorded hash until fiskroad is published). Divergence fails the build.

| REQ | Requirement | TC | Test criteria | Method |
|---|---|---|---|---|
| REQ-DCE-05 | Registry class names match the program vocabulary exactly | TC-VOC-03 | CI comparison against `vocabulary.yaml`; a renamed class fails | CI |
| REQ-DCE-06 | `regulated-identifier` is unapprovable | TC-VOC-04 | A deliberate registry entry approving it fails validation and CI | CI |

## 2. P-2 — Tenant Identifier In Key And Team Metadata (X2, enforcement half)

Virtual-key issuance and team metadata carry `tenant_id` as the canonical lowercase UUID per the shared vocabulary. `provision-desktop-keys.ps1` and any key-issuance documentation are updated to state the format and to reject non-UUID values at issuance time — the gateway is the earliest point the program can stop a string tenant from entering the ledger.

| REQ | Requirement | TC | Test criteria | Method |
|---|---|---|---|---|
| REQ-DCE-07 | Key issuance rejects non-UUID `tenant_id` | TC-VOC-05 | Issuing a key with `TENANT_ALPHA` fails with a format error naming the rule | CI or DEMO |

## 3. P-3 — Endpoint Detection Contract (X5; popeye owns, nono implements its half)

TC-END-02 (a bypass attempt is detected and reported) currently has two capable components and no contract between them. This section is that contract; it is deliberately POC-grade.

**3.1 Policy profile (what nono enforces).** A named profile, `twg-gateway-only`, expressed in nono's allowlist terms:

- Allow: the gateway internal FQDN (and, once X7/S3 lands, `gateway-azure.ai.twg.internal`).
- Block: direct model-provider domains — at minimum `api.openai.com`, `api.anthropic.com`, `*.openai.azure.com`, `bedrock*.amazonaws.com`, `generativelanguage.googleapis.com`.
- Credential injection: the per-user virtual key is injected by `nono-proxy` for allowed gateway traffic, so the governed path is also the zero-configuration path.

The profile's content is owned here (popeye owns endpoint policy); its encoding into nono configuration is nono's half (see nono's v0.3 note).

**3.2 Detection event (what nono emits).** One JSON object per blocked attempt:

```json
{
  "schema": "endpoint-detection/0.1",
  "occurred_at": "<ISO-8601 UTC>",
  "workstation": "<hostname>",
  "os_user": "<user principal name>",
  "process": "<image name or path>",
  "destination": "<blocked host>",
  "action": "blocked",
  "profile": "twg-gateway-only"
}
```

No prompt content, no request bodies — the event records that an attempt happened, not what it said. Fields are the minimum an analyst needs to follow up.

**3.3 Transport (POC-grade).** Events append to a local JSONL file; the demo forwards that file (manually is acceptable) and a popeye-side ingestion script raises the roadmap 7.3 "nono detections" notify alert from it. A production pipeline (Log Analytics agent, event hub) is explicitly deferred to Stage 3 fleet rollout.

**3.4 Demo criterion.** One detection travels end to end: a workstation process attempts `api.openai.com`, nono blocks and emits the event, the event reaches the popeye side, the notify alert fires.

| REQ | Requirement | TC | Test criteria | Method |
|---|---|---|---|---|
| REQ-END-03 | The `twg-gateway-only` profile blocks direct provider access and allows the gateway | TC-END-02a | Live demonstration on a managed workstation | DEMO |
| REQ-END-04 | Detections are emitted in the contract schema, content-free | TC-END-02b | Schema validation of emitted events; review confirms no body fields | CI + AUDIT |
| REQ-END-05 | A detection reaches popeye alerting | TC-END-02c | End-to-end demo per 3.4 | DEMO |

## 4. P-4 — Fallback Chain: Implement Or Amend (carried item, decision required)

The rendered config declares one model and no `fallbacks:` block, so TC-REL-02 (provider failure absorbed by fallback) and the substantive half of TC-COST-04 (cross-cloud split) cannot be demonstrated. The kickoff's descope rules permit single-provider operation — but require saying so.

Decide one, in writing, before the POC:

- **Option A:** add the Bedrock backend and a fallback chain for the `twg-foundry` model group. This is the smaller lift than it appears — the config schema already anticipates it — and it makes both criteria demonstrable.
- **Option B:** amend the Stage 1 exit criteria to mark TC-REL-02 and TC-COST-04 deferred-to-Stage-3, and carry that statement into `STAGE1_BASELINES.md` so the baseline document says it rather than a reviewer discovering it.

Either is defensible. Undecided is not.

## 5. P-5 — Housekeeping (X7 share)

- Rename `specs/ROADMAP_integration_popeye.md` → `specs/ROADMAP.md`; update `specs/README.md` and `STATE.md` references. hometown completed this consolidation; the fiskroad glossary already claims it is done here.
- Update the STATE.md `Last updated:` line, which predates the content it describes.
