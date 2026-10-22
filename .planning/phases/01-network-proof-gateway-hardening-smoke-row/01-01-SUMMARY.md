---
phase: 01-network-proof-gateway-hardening-smoke-row
plan: 01
subsystem: gateway-hardening
tags: [litellm, ghsa, ci, python, gitignore]
requires: []
provides:
  - "GW-02 advisory range gate (config/litellm-advisory-ranges.json + scripts/Test-LitellmAdvisoryRange.py)"
  - "Pin-file mode ready for plan 01-06"
  - "gitignore negation for envs/azure-eastus2/litellm-pin.auto.tfvars"
affects: [01-06]
tech-stack:
  added: []
  patterns: ["stdlib-only Python checker with --self-test", "half-open version ranges"]
key-files:
  created:
    - scripts/Test-LitellmAdvisoryRange.py
    - config/litellm-advisory-ranges.json
  modified:
    - .gitignore
    - envs/azure-eastus2/terraform.tfvars.example
    - .github/workflows/terraform.yml
key-decisions:
  - "Advisory ranges committed (17 GHSAs fetched via gh api on 2026-10-22); script never uses the network"
  - "-stable-suffixed advisory ranges converted to plain half-open numeric bounds"
requirements-completed: [GW-02, GW-01]
duration: 10min
completed: 2026-10-22
---

# Phase 1 Plan 01: Advisory Range Gate Summary

Stdlib-only LiteLLM GHSA range checker with 17 committed advisories, self-test wired into the existing terraform.yml, plus the gitignore negation and tfvars.example cleanup needed by the later pin plan.

## Tasks
1. Advisory range file and checker: commit 53c3edd. Self-test prints 20 PASS lines, exit 0. Default mode exits 1 with "GW-02: pin file missing" (expected until plan 06).
2. gitignore, tfvars.example, CI step: commit c5691d5. Pin path not ignored; `artifacts/x.raw.json` ignored; `terraform fmt -check -recursive` exit 0.

## Deviations from Plan
- Worktree base was corrected with `git reset --hard 890adcf` per the startup branch check (tree was clean, base was an earlier commit).
- Advisories beyond the six seeded were added from the API (11 more, 17 total). Ranges whose API text used `-stable` suffixes were normalised to numeric bounds; GHSA-hx8v (`<=1.83.8`) became `[0.0.0, 1.83.9)`.
- Self-test pin-file cases use a temp directory instead of a repo path.

## Known Stubs
None. The real pin file is intentionally absent until plan 01-06 (D-16).

## Self-Check: PASSED
