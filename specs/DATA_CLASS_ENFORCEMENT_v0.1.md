# Data-Class Enforcement At The Gateway

Version: 0.1
Status: Draft — implements the enforcement half of the Fiskroad regulated data controls
Audience: popeye team
Primary post-read action: confirm the key-metadata and allowlist derivation approach, then implement ahead of the POC.
Companion: `fiskroad/specs/REGULATED_DATA_CONTROLS_v0.1.md` (the policy this enforces).

## 1. What This Adds

Popeye already enforces model allowlists per virtual key. This specification makes those allowlists *derived from data classification* rather than hand-maintained, so the compliance control and the technical control cannot drift apart.

Popeye remains semantics-blind. It does not inspect prompt content, does not classify data, and does not know what any request means. It enforces a mapping between two labels it is given: the class a key is permitted to handle, and the class each model is approved for. That distinction is what keeps this inside popeye's boundary.

## 2. Mechanism

1. **Model approval registry** — the approved-model list from the policy document, expressed as configuration in the popeye repository: model deployment to maximum approved data class. Source-controlled, reviewed like any config, and the single input to allowlist generation.
2. **Key metadata** — every virtual key carries `data_class` (the declared maximum class of the feature or application it serves) alongside the existing `app_id`, `team_id`, and feature tagging.
3. **Derived allowlist** — a key's permitted model set is computed as every model whose approved class is greater than or equal to the key's `data_class`. Allowlists are generated, never hand-edited; a hand-edited allowlist is a defect.
4. **Rejection** — a request for a model outside the derived set is refused with a policy error class distinct from both budget exhaustion and provider throttling, naming the class mismatch without echoing any request content.
5. **Audit** — key issuance records the `data_class` and the derivation inputs; the admin audit log carries changes to the approval registry.

## 3. Guardrails

- Deny by default: a key with no declared `data_class` is treated as `internal` and reaches only models approved for `internal` or above.
- No content inspection. Popeye classifies nothing; it enforces labels supplied by the classification process.
- Approval registry changes are reviewed changes, not runtime edits.
- The registry is per cloud. A model approved on Azure confers nothing on its Bedrock counterpart, because the contractual terms differ.
- Break-glass credentials bypass the gateway and therefore bypass this control. That is an accepted and recorded property of break-glass, and it is a reason the procedure is time-boxed, dual-approved, and audited — state it rather than discovering it in review.

## 4. Requirements Served

Implements TC-REG-01, TC-REG-03, and TC-REG-05 from the program control document. TC-REG-03 is the demonstrable one: a regulated-feature key refused a non-approved model, with a clean, distinguishable error.

## 5. Open Decisions

- Whether `data_class` lives in key metadata, team metadata, or both. Recommendation: team metadata as the default with key-level override, mirroring how budgets already work.
- Whether allowlist generation runs in CI against the registry or at key-issuance time. Recommendation: CI, so drift is caught before it reaches a key.
