---
quick_id: 261104-p2v
status: complete
completed: 2026-11-04
---

Egress probe: all destinations reach TCP 443; HTTPS OK except aka.ms, where a Windows PowerShell 5.1 HEAD/no-redirect quirk throws (TCP OK, and the az install via aka.ms then succeeded). Tooling is installed on EUS-VM-POPEYE: Azure CLI 2.92.0 and psql 16.4. psql first failed with 0xC0000135 (missing Visual C++ runtime) and worked after a one-off vc_redist install.

Script changes:
- `Install-PopeyeVmTooling.ps1` now installs the Visual C++ runtime, reports psql's exit code and re-reads PATH.
- `Test-PopeyeVerificationVm.ps1 -CheckTooling` re-reads PATH.
- Both scripts turn off positional binding and reject unexpected arguments.

Verified on the VM: CheckTooling PASS/PASS, and an installer dry run reports all three already present. psql-on-vm and az-on-vm are now yes. Plan 01-08 is still held on NET-03 (env DNS zone) and NET-06 (User Login).
