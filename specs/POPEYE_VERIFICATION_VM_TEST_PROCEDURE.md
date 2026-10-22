# Popeye Verification VM Test Procedure

Use this after the temporary Stage 1/2 verification VM is provisioned. It separates Azure administrator checks from the checks that run from the VM.

## Azure administrator checks

1. Confirm the VM NIC has no public IP and that the VM is in a new non-delegated subnet in `vnet-popeye-stage1-stage2-eastus2`.
2. Confirm direct inbound RDP is not permitted. Confirm administration is through Azure Bastion only. A normal Bastion public IP is allowed; the VM itself must not have one.
3. If a dedicated Bastion host was deployed, confirm its subnet is named `AzureBastionSubnet` and is `/26` or larger.
4. Confirm Microsoft Entra sign-in is enabled on the VM. Only Oscar Mack and Roger may have the required narrow-scope Reader permissions and `Virtual Machine User Login` (or Administrator Login only where approved).
5. Confirm `privatelink.postgres.database.azure.com` is linked to the Popeye VNet and contains the existing PostgreSQL private-endpoint record. Do not change DNS records or add a link unless the current configuration fails validation.
6. Inspect NSGs and UDRs; permit only the required VM-to-private-endpoint TCP 5432 traffic. Do not enable PostgreSQL public network access.
7. Confirm Key Vault access is restricted to `litellm-reader-dsn` after it exists. Do not grant the VM identity or either operator access to `litellm-database-url`, writer, master, or salt secrets.

## VM connectivity checks

In an Azure Bastion session on the verification VM, run:

```powershell
Set-Location C:\path\to\popeye
.\scripts\Test-PopeyeVerificationVm.ps1
```

The output must report PASS for DNS resolution to an RFC1918 address, TCP 5432, and no VM public IP.

After `ekg_cube_reader` and the `litellm-reader-dsn` secret have been verified, run the optional authenticated check. Do not paste the DSN into tickets, logs, or screenshots.

```powershell
$dsn = az keyvault secret show --vault-name kv-popeye-gw-98c2b71b --name litellm-reader-dsn --query value -o tsv
.\scripts\Test-PopeyeVerificationPsql.ps1 -Dsn $dsn
Remove-Variable dsn
```

Record the command summary, VM name/private IP, Bastion resource, validation date, and any approved minimum DNS/NSG/UDR changes. Configure scheduled shutdown and decommission by 2026-09-03 unless an extension is approved.
