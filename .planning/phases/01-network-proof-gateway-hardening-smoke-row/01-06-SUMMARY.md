---
phase: 01-network-proof-gateway-hardening-smoke-row
plan: 06
subsystem: gateway
tags: [litellm, terraform, container-apps, hardening, ci]
requires: ["01-01", "01-04", "01-05"]
provides: [digest-pinned image, hardened rendered config, CI pin gate]
affects: [01-07]
key-files:
  created: [envs/azure-eastus2/litellm-pin.auto.tfvars]
  modified:
    - modules/gateway-service-azure/main.tf
    - modules/gateway-service-azure/variables.tf
    - envs/azure-eastus2/main.tf
    - envs/azure-eastus2/variables.tf
    - config/litellm.azure.example.yaml
    - .github/workflows/terraform.yml
requirements: [GW-01, GW-02, GW-03, GW-04, GW-05, GW-06]
completed: 2026-10-23
---

# Phase 01 Plan 06: LiteLLM 1.106.x upgrade and hardening code Summary

Code-only: LiteLLM v1.106.2 is pinned by tag and digest, with exec PID 1, a 45 s grace period, hardened rendered config and an explicit coordination Redis. Nothing was planned or applied.

## Tasks
1. Service module (commit "feat(01-06): digest-pinned image, exec, ..."): image is `tag@digest`; tag regex `^v1\.\d+\.\d+$` plus the existing latest/empty check; new `litellm_image_digest` with sha256 regex; `exec litellm`; `termination_grace_period_seconds = 45`; env `DISABLE_ADMIN_UI=True`, `LITELLM_LOG=ERROR`, `PROXY_BATCH_WRITE_AT=10`; readiness on `/health/readiness`; startup probe threshold 60. `min_replicas >= 2` validation untouched. No cache settings.
2. Root and config (commit "feat(01-06): hardened rendered config ..."): digest variable plus pass-through; `general_settings` gains `user_api_key_cache_ttl: 30`, `allow_client_side_credentials: false`, `disable_env_credential_login: true` and `coordination_redis` (port rendered from `module.state.redis_ssl_port`, ssl true). Example YAML mirrored with `port: 10000`. No `cache`/`cache_params`.
3. Pin file and CI (commit "feat(01-06): commit LiteLLM pin file ..."): `envs/azure-eastus2/litellm-pin.auto.tfvars` with only `litellm_image_tag` and `litellm_image_digest`; CI step `GW-02 check pinned LiteLLM version against advisory ranges` added; placeholder comment removed.

## Verification
- `terraform fmt -check -recursive` exit 0; `init -backend=false` + `validate` Success (confirms `termination_grace_period_seconds` is accepted by azurerm 4.80 template block).
- `Test-LitellmAdvisoryRange.py --self-test` and default mode both exit 0.
- Negative check: pin temporarily set to v1.100.3 gave exit 1 with "GW-02: v1.100.3 is inside GHSA-7hp6-4w63-5g45 range"; reverted (file restored to v1.106.2).

## Deviations from Plan
- [Rule 1 - Bug] The tag-regex `error_message` initially used `\.`/`\d`, which HCL rejects as invalid escapes; fixed by doubling backslashes in the condition and using `[.]` in the message text. Code is in the committed state; validate passes.
- Network not used: the digest and v1.106.2 tag were not re-verified against GHCR/upstream. Plan 01-07 Task 1 must re-verify both on apply day (D-03).
- The `git check-ignore` acceptance check was not run in its standalone form (sandbox refused the command shape); the pin file is committed and tracked, which was the intent.

## Notes for 01-07
- Assumption A1: if ACA rejects `tag@digest` on first apply, fall back to digest-only (comment left in module main.tf).
- Assumption A2 avoided by rendering the Redis port as a number.

## Known Stubs
None.

## Self-Check: PASSED
