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
