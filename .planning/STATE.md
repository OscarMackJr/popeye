---
gsd_state_version: 1.0
milestone: v0.3
milestone_name: milestone
status: executing
last_updated: "2026-10-22T21:48:27.114Z"
last_activity: 2026-10-23
progress:
  total_phases: 8
  completed_phases: 0
  total_plans: 9
  completed_plans: 7
  percent: 0
---

# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-10-22)

**Core value:** Every governed model call is attributed. Each completion lands one ledger row with the correct principal, and agent keys can be minted, introspected and revoked under the rules nono depends on.
**Current focus:** Phase 01 — network-proof-gateway-hardening-smoke-row

## Current Position

Phase: 01 (network-proof-gateway-hardening-smoke-row) — EXECUTING
Plan: 2 of 9
Status: Ready to execute
Last activity: 2026-11-04 - Completed quick task 261104-p2v: VM egress open, az 2.92.0 and psql 16.4 installed on EUS-VM-POPEYE

Progress: [████████░░] 78%

## Performance Metrics

**Velocity:**

- Total plans completed: 0
- Average duration: -
- Total execution time: 0 hours

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| - | - | - | - |

**Recent Trend:**

- Last 5 plans: -
- Trend: -

*Updated after each plan completion*
| Phase 01 P02 | multi-session | 3 tasks | 5 files |

## Accumulated Context

### Decisions

Decisions are logged in the PROJECT.md Key Decisions table.
Recent decisions affecting current work:

- [Roadmap]: nono critical path is 1 -> 2 -> 3 (+4) -> 5 -> 6. TC-AGT-21 (INT-11) is the nono integration gate.
- [Roadmap]: Phase 2 can run alongside Phase 1, and Phase 4 alongside Phase 3.
- [Roadmap]: NET-07 (temporary access review) is placed in Phase 8 because the peered caller VM is also the runner for the smoke test, the Stage 1 measurements and the DLP evaluation.
- [2026-10-22]: Network design is peering. Callers in `EUS-POPEYE-VNET-01` reach the Stage 1/2 VNet over VNet peering, replacing the proposal for a VM and Bastion inside the Stage 1/2 VNet.
- [Roadmap]: Phases needing `--research-phase`: 1, 3 (highest), 4 (FQDN routing), 5, 6, 8 (DLP).
- [Phase 01]: 01-07: LiteLLM v1.106.2@digest live 2026-10-23; backup pre-litellm-1106-20261023; coordination_redis log line unobservable under LITELLM_LOG=ERROR, proof moves to 01-08
- [Phase 01]: 01-05: networking-owns branch; litellm-reader-dsn applied 2026-10-23; env DNS Terraform count-gated off
- [Phase 01]: 01-04: Redis clustering policy stays NoCluster (spike all PASS over the private endpoint); Redis publicNetworkAccess Disabled 2026-10-23
- [Phase 01]: Phase 01-02: env DNS zone owned by networking; D-08 extended to database-url/reader-dsn (user-approved); VM tooling via Install-PopeyeVmTooling.ps1 before plan 08

### Pending Todos

None yet.

### Blockers/Concerns

- Plan 01-08 HELD (2026-10-23). EUS-VM-POPEYE has no outbound internet: the psql/az install failed, and operator `az login` on the VM also needs Entra/ARM/Key Vault egress. The env DNS zone (NET-03) is also still pending. Both are networking asks. The D-08 database-url grant extension is already approved (2026-10-22).
  - 2026-10-27: `scripts/Test-PopeyeVmEgress.ps1` shows all six destinations resolve but time out on TCP 443 (dropped on the Azure path). Results go back to networking. Networking is creating the env DNS zone and has removed `Allow_Iliya_Promenet`; NET-06 User Login is unconfirmed. Re-run the probe after their egress change.
  - 2026-11-03: Networking asked where the traffic comes from. Reply: from EUS-VM-POPEYE itself (subnet 10.10.2.0/24), with the destination list and the NET-06 question repeated. The subnet read shows `defaultOutboundAccess` false with no NAT gateway or route table, so it has no outbound path. Networking needs to add one.
  - 2026-11-03 (later): Networking says no egress is by design. Security rejected a public IP, and no central firewall exists yet. They offered an approved temporary method. We requested a time-boxed NAT gateway with NSG outbound limited to the AzureActiveDirectory/AzureResourceManager/AzureKeyVault service tags, plus an installer option (install window, staged installers, or a Bastion Basic to Standard upgrade), and asked for the central firewall's date. NET-06 is pending their check.
  - 2026-11-04: Egress is open: a NAT gateway, with NSG Internet outbound limited to TCP 443 (broader than the service-tag proposal). Our probe confirms it, with aka.ms HTTPS FAIL as a PS 5.1 probe quirk. az 2.92.0 and psql 16.4 are installed on the VM (psql needed the VC++ runtime), so psql-on-vm and az-on-vm are yes. Postgres now resolves to 10.60.2.4, not 10.60.2.5 (Flexible Server IP move; FQDN-based, no impact). Plan 01-08 is still held on NET-03 and NET-06.

- Operator workstation: a TLS-intercepting proxy breaks az data-plane calls (`containerapp logs show`, `log-analytics query`). Read logs in the portal. A REQUESTS_CA_BUNDLE fix is an IT decision.

- The peered-caller data-plane test passed on 2026-10-22 (`artifacts/popeye-peered-caller-connectivity-2026-10-22.md`):
  - Postgres DNS resolves to 10.60.2.5;
  - TCP 5432 connects;
  - the Container Apps environment answers on 10.60.0.108:443;
  - the environment domain does not resolve. Outstanding networking asks:
  - a Container Apps environment private DNS zone (`ashyglacier-edb44cd7.eastus2.azurecontainerapps.io` → 10.60.0.108), linked to both VNets; without it the gateway FQDN does not resolve and the smoke test is blocked;
  - removing the internet-sourced RDP rule `Allow_Iliya_Promenet`;
  - User Login for both approved operators.
- `EUS-VM-POPEYE` login: the extra assignments were removed (2026-10-22). Only OMack remains, with Administrator Login. Roger needs User Login, and OMack should drop to User Login or record approval for Admin (NET-06).
- Program/nono decisions needed early in Phase 2: G11 (`on_behalf_of` format, one-way door), G2 (budget model, before any fleet mint), the `direct_gateway` default, and the G3 admin-revocation carve-out (OPS-03 depends on it).
- Hook internals are LOW confidence until the Phase 3 spike, which gates the Phase 5 metadata contract.
- The 60s revocation bound may be read as end-to-end (about 120s worst case). Clarify with nono, hometown and olive before Phase 6.

### Quick Tasks Completed

| # | Description | Date | Commit | Directory |
|---|-------------|------|--------|-----------|
| 261023-d0i | Close out plan 01-04 Redis private cutover with operator evidence | 2026-10-23 | docs(quick-261023-d0i) | [261023-d0i-close-out-plan-01-04-redis-private-cutov](./quick/261023-d0i-close-out-plan-01-04-redis-private-cutov/) |
| 261027-j3d | Record 2026-10-27 VM egress probe and add Test-PopeyeVmEgress.ps1 | 2026-10-27 | docs(quick-261027-j3d) | [261027-j3d-record-2026-10-27-vm-egress-probe-and-ad](./quick/261027-j3d-record-2026-10-27-vm-egress-probe-and-ad/) |
| 261103-k7m | Record 2026-11-03 networking reply (VM egress source) in the preflight artifact | 2026-11-03 | docs(quick-261103-k7m) | [261103-k7m-record-2026-11-03-networking-reply-vm-egre](./quick/261103-k7m-record-2026-11-03-networking-reply-vm-egre/) |
| 261103-m4q | Record networking's egress design response and the temporary-egress follow-up | 2026-11-03 | docs(quick-261103-m4q) | [261103-m4q-record-networking-egress-design-response](./quick/261103-m4q-record-networking-egress-design-response/) |
| 261104-p2v | Record VM egress opened and tooling installed; fix tooling scripts for run-command | 2026-11-04 | docs(quick-261104-p2v) | [261104-p2v-record-vm-egress-open-and-tooling-install](./quick/261104-p2v-record-vm-egress-open-and-tooling-install/) |

## Deferred Items

| Category | Item | Status | Deferred At |
|----------|------|--------|-------------|
| *(none)* | | | |

## Session Continuity

Last session: 2026-10-22T21:48:14.181Z
Stopped at: Phase 1 context gathered
Resume file: None
