# Popeye MVP Ceremony Runbook v0.1

Operator runbook for the plan 01-08 admin ceremony: the smoke row, lockdown checks, shared budget counters and restart flush (MVP-01, GW-03, GW-04, GW-06), plus the NET-04 session evidence that plan 01-09 uses. This runbook turns 01-08 Task 2 into copy-paste steps. The plan (`.planning/phases/01-network-proof-gateway-hardening-smoke-row/01-08-PLAN.md`) and `specs/POPEYE_VERIFICATION_VM_TEST_PROCEDURE.md` step 7 remain authoritative. Where this runbook differs from the plan, it says so.

Status: drafted 2026-11-11, after NET-06 was verified. Steps 0a and 0b (copying the kit and installing PowerShell 7 through run-command) have not been run yet. Run them at least a day before the ceremony.

## Who runs it

The **platform owner (Oscar)** runs it, in a normal **non-admin** Bastion session on `EUS-VM-POPEYE`. "Admin" refers to the Azure and LiteLLM credentials the ceremony uses, not to Windows. Don't reinstate Virtual Machine Administrator Login: NET-06 requires that nobody holds it without written approval.

| Privilege | Source |
|---|---|
| LiteLLM master key (mint, block and inspect keys) | Time-boxed **Key Vault Secrets User** scoped to the single secret `litellm-master-key` (procedure step 7a) |
| Postgres admin, to create `ekg_cube_reader` | The same kind of grant on `litellm-database-url` (procedure step 7c, confirmed 2026-10-22) |
| Reader DSN for the row assertions | The same kind of grant on `litellm-reader-dsn` |
| Creating and removing those grants | Owner, User Access Administrator or Role Based Access Control Administrator on `kv-popeye-gw-98c2b71b`, from the operator workstation |
| Revision restart, replica list, console access to a replica, log queries | Contributor on the gateway Container App; Log Analytics Reader |

The VM's managed identity gets no Key Vault grant (procedure step 7e). Secret-touching steps run only in the interactive Bastion session, under the operator's own `az login` (D-18). Run-command is used only for steps that touch no secret (0a, 0b).

Optional: the second operator (Oleg) watches the operator's screen. It isn't required.

## Values

| Name | Value |
|---|---|
| Key Vault | `kv-popeye-gw-98c2b71b` |
| Gateway app | `popeye-stage1-stage2-eastus2-app` |
| Gateway resource group | `rg-popeye-stage1-stage2-eastus2` |
| Gateway FQDN | `popeye-stage1-stage2-eastus2-app.internal.ashyglacier-edb44cd7.eastus2.azurecontainerapps.io` → 10.60.0.108 |
| Postgres | `pg-popeye-stage1-stage2-eastus2.postgres.database.azure.com` |
| VM | `EUS-VM-POPEYE` in resource group `EUS-RG-POPEYE-VM-01`, through `EUS-POPEY-BASTION` (Basic SKU) |

Allow about 90 minutes in one sitting, and write down a **UTC timestamp for every step**. On the VM, Windows PowerShell 5.1 has no `Get-Date -AsUTC`; use `(Get-Date).ToUniversalTime()`.

---

## 0. Preparation (workstation, at least a day before)

### 0a. Copy the scripts onto the VM

Basic SKU Bastion has no file transfer, so the kit goes over run-command. Nothing secret is involved. Run this from the repository root in PowerShell 7:

```powershell
$stage = "$env:TEMP\popeye-kit"; Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory "$stage\scripts","$stage\sql","$stage\config" | Out-Null
Copy-Item scripts\Set-PopeyeLedgerReader.ps1,scripts\Invoke-PopeyeSmoke.ps1,scripts\Test-PopeyeGatewayLockdown.ps1,scripts\Test-PopeyeVerificationPsql.ps1,scripts\Test-PopeyeVerificationVm.ps1 "$stage\scripts"
Copy-Item sql\ai_usage_grants_azure.sql "$stage\sql"; Copy-Item config\llm-allowed-routes.json "$stage\config"
Compress-Archive "$stage\*" "$env:TEMP\popeye-kit.zip" -Force
$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes("$env:TEMP\popeye-kit.zip"))
@"
`$b = '$b64'
New-Item -ItemType Directory C:\popeye-kit -Force | Out-Null
[IO.File]::WriteAllBytes('C:\popeye-kit\kit.zip',[Convert]::FromBase64String(`$b))
Expand-Archive C:\popeye-kit\kit.zip C:\popeye-kit -Force
Get-ChildItem C:\popeye-kit -Recurse -File -Exclude kit.zip | Get-FileHash | ForEach-Object { "`$(`$_.Hash.Substring(0,12))  `$(Split-Path `$_.Path -Leaf)" }
"@ | Set-Content "$env:TEMP\deploy-kit.ps1"
az vm run-command invoke -g EUS-RG-POPEYE-VM-01 -n EUS-VM-POPEYE --command-id RunPowerShellScript --scripts "@$env:TEMP\deploy-kit.ps1"
Get-ChildItem $stage -Recurse -File | Get-FileHash | ForEach-Object { "$($_.Hash.Substring(0,12))  $(Split-Path $_.Path -Leaf)" }
```

The hash list from the VM must match the one printed on the workstation. The kit keeps the `scripts/`, `sql/` and `config/` layout, because `Set-PopeyeLedgerReader.ps1` and `Invoke-PopeyeSmoke.ps1` find their SQL and routes files relative to `$PSScriptRoot`.

### 0b. Install PowerShell 7 on the VM

The ceremony scripts need PowerShell 7 (`-SkipHttpErrorCheck`, `SHA256.HashData`), and the VM has only Windows PowerShell 5.1. Run-command runs as SYSTEM, so no Windows admin session is needed:

```powershell
@'
[Net.ServicePointManager]::SecurityProtocol = 'Tls12'
iex "& { $(irm https://aka.ms/install-powershell.ps1) } -UseMSI -Quiet"
& 'C:\Program Files\PowerShell\7\pwsh.exe' -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
'@ | Set-Content "$env:TEMP\install-pwsh.ps1"
az vm run-command invoke -g EUS-RG-POPEYE-VM-01 -n EUS-VM-POPEYE --command-id RunPowerShellScript --scripts "@$env:TEMP\install-pwsh.ps1"
```

It should print a 7.x version. Start a **new** Bastion session afterwards so PATH picks it up.

### 0c. Decide what to do about 422 versus 429

The scripts and the plan expect **422** when a budget runs out (LiteLLM 1.106). Program requirement TC-GOV-01 says 429. Decide which one the evidence and the CTO demo will show before the ceremony, and amend whichever document loses.

### 0d. Known weak spot: per-replica request attribution

Step 8 has to show which replica served each request. The gateway runs with `LITELLM_LOG=ERROR`, and in 01-07 the Redis coordination log line couldn't be seen at that level, so request IDs may not appear in the logs. If they don't, use the plan's fallback (per-replica request counts from `az containerapp logs show --replica <name>`) and record the method. If neither works, record a gap. **Don't change the log level during the ceremony.**

---

## 1. Grant (workstation): start of the privileged window, T0

```powershell
$oid = az ad signed-in-user show --query id -o tsv
$kv  = az keyvault show -n kv-popeye-gw-98c2b71b --query id -o tsv
foreach ($s in 'litellm-master-key','litellm-database-url','litellm-reader-dsn') {
  az role assignment create --assignee-object-id $oid --assignee-principal-type User `
    --role "Key Vault Secrets User" --scope "$kv/secrets/$s" --query id -o tsv }
(Get-Date).ToUniversalTime()   # T0
```

Never grant at vault scope. Role assignments can take a few minutes to take effect.

## 2. Bastion session and NET-04 evidence

1. Connect to `EUS-VM-POPEYE` through Bastion with **Microsoft Entra ID** authentication.
2. Note the session start time in UTC.
3. Open **PowerShell 7** (`pwsh`) and run:

```powershell
Set-Location C:\popeye-kit
az login --use-device-code          # as the platform owner
$gw  = 'https://popeye-stage1-stage2-eastus2-app.internal.ashyglacier-edb44cd7.eastus2.azurecontainerapps.io'
$kvn = 'kv-popeye-gw-98c2b71b'
$tid = (az account show --query tenantId -o tsv).ToLowerInvariant()
$oid = az ad signed-in-user show --query id -o tsv
.\scripts\Test-PopeyeVerificationVm.ps1 -GatewayFqdn ($gw -replace 'https://') -ExpectedGatewayIp 10.60.0.108
```

Record the four NET-04 rows (DNS and TCP 5432 to Postgres, DNS and TCP 443 to the gateway) with the session window. These are plan 01-09's Bastion-session NET-04 evidence.

If Conditional Access blocks device-code sign-in, run `az login` without the flag and use the browser in the Bastion session.

> **Deviation from the plan: run every script in-process, `& .\scripts\X.ps1`, never `pwsh scripts/X.ps1`.** The plan writes `$r = pwsh scripts/...`. Launching a child `pwsh` turns the output into plain text, so `$r.Key` (a SecureString) and `$r.KeyHash` would be empty. Record this deviation in the evidence.

## 3. Check that Foundry is healthy

```powershell
$mk = az keyvault secret show --vault-name $kvn --name litellm-master-key --query value -o tsv
(Invoke-WebRequest "$gw/health?model=twg-foundry" -Headers @{Authorization="Bearer $mk"} -SkipHttpErrorCheck).StatusCode
Remove-Variable mk
```

Expect 200 with a healthy endpoint. If it isn't healthy, stop: fix the gateway identity's Foundry permissions or `foundry_scope_id` first.

## 4. Create the ledger reader role (D-13)

```powershell
& .\scripts\Set-PopeyeLedgerReader.ps1 -KeyVaultName $kvn
& .\scripts\Set-PopeyeLedgerReader.ps1 -KeyVaultName $kvn -VerifyOnly
& .\scripts\Set-PopeyeLedgerReader.ps1 -KeyVaultName $kvn          # re-run: proves idempotence
```

This is the only step that needs `litellm-database-url`. To shorten that grant's window, remove it from the workstation now:

```powershell
az role assignment delete --assignee $oid --role "Key Vault Secrets User" --scope "$kv/secrets/litellm-database-url"
```

## 5. Smoke test: the MVP-01 row

```powershell
$t0 = (Get-Date).ToUniversalTime()
$r = & .\scripts\Invoke-PopeyeSmoke.ps1 -Action Run -GatewayBaseUrl $gw -KeyVaultName $kvn -TenantId $tid -UserObjectId $oid
```

The script prints the timestamp, `RequestId`, HTTP 200, `twg-foundry` and the first 8 characters of the key hash. Record that line.

## 6. Lockdown checks (GW-03)

```powershell
& .\scripts\Test-PopeyeGatewayLockdown.ps1 -GatewayBaseUrl $gw -UserKey $r.Key; $LASTEXITCODE   # expect 0
```

Every row should PASS, including the 200 positive control and the D-19 admin-UI rows.

## 7. Confirm the row through the read-only path (MVP-01)

```powershell
$dsn = az keyvault secret show --vault-name $kvn --name litellm-reader-dsn --query value -o tsv
& .\scripts\Test-PopeyeVerificationPsql.ps1 -Dsn $dsn -KeyHash $r.KeyHash -RequestId $r.RequestId `
   -SinceUtc $t0.AddMinutes(-5) -ExpectedUserId $oid -ExpectedKeyAlias "user:$oid" -ExpectedTenantId $tid
```

Expect PASS: exactly one row, and team, user, key alias and tag all match. If the script prints an INFO line about `principal_type`, copy it into the evidence.

## 8. Shared budget counters and cross-replica proof (GW-06)

1. Run the budget probe. It mints its own probe key, prints a histogram of status codes and blocks the key itself:

   ```powershell
   & .\scripts\Invoke-PopeyeSmoke.ps1 -Action BudgetProbe -GatewayBaseUrl $gw -KeyVaultName $kvn -TenantId $tid -UserObjectId $oid
   ```

2. List the replicas. There must be at least two:

   ```powershell
   az containerapp replica list -n popeye-stage1-stage2-eastus2-app -g rg-popeye-stage1-stage2-eastus2 --query "[].name" -o tsv
   ```

3. Take the "before" snapshot of Redis key names (names only, never values):

   ```powershell
   az containerapp exec -n popeye-stage1-stage2-eastus2-app -g rg-popeye-stage1-stage2-eastus2 --command sh
   ```

   Inside the replica, run:

   ```sh
   python -c "import os,redis,collections;c=redis.Redis(host=os.environ['REDIS_HOST'],port=int(os.environ.get('REDIS_PORT','10000')),password=os.environ.get('REDIS_PASSWORD'),ssl=True);print(collections.Counter(k.decode().split(':')[0] for k in c.scan_iter(count=500)))"
   ```

   Then type `exit`.

4. Send 12 completions on one key. `$x.RequestIds` holds the 12 request IDs:

   ```powershell
   $x = & .\scripts\Invoke-PopeyeSmoke.ps1 -Action Run -Count 12 -GatewayBaseUrl $gw -KeyVaultName $kvn -TenantId $tid -UserObjectId $oid
   ```

5. Take the "after" snapshot by repeating point 3. Confirm the spend and budget counter key counts went up and no response-cache key prefixes exist.

6. Work out which replica served each request. Run this from the VM or the portal; the operator workstation's TLS proxy breaks `az` log queries:

   ```kusto
   ContainerAppConsoleLogs_CL | where ContainerGroupName_s == '<replica>' | where Log_s has '<request_id>'
   ```

   If that finds nothing, use the fallback in 0d.

Record replica labels (replica-1, replica-2), the request count per replica, and the before and after key-name counts.

## 9. Restart with no lost rows (GW-04)

```powershell
$rev = az containerapp revision list -n popeye-stage1-stage2-eastus2-app -g rg-popeye-stage1-stage2-eastus2 --query "[?properties.active].name | [0]" -o tsv
$t9 = (Get-Date).ToUniversalTime()
$f = & .\scripts\Invoke-PopeyeSmoke.ps1 -Action Run -Count 3 -GatewayBaseUrl $gw -KeyVaultName $kvn -TenantId $tid -UserObjectId $oid
az containerapp revision restart -n popeye-stage1-stage2-eastus2-app -g rg-popeye-stage1-stage2-eastus2 --revision $rev   # within 5 s of the line above
Start-Sleep 60
& .\scripts\Test-PopeyeVerificationPsql.ps1 -Dsn $dsn -KeyHash $f.KeyHash -SinceUtc $t9.AddMinutes(-5) -ExpectedCount 3
```

Expect PASS with exactly 3 rows.

## 10. Cleanup: end of the privileged window, T1

1. On the VM, block the smoke keys. They are blocked, never deleted (D-10). Then confirm each blocked key is refused:

   ```powershell
   foreach ($k in $r.Key,$x.Key,$f.Key) { & .\scripts\Invoke-PopeyeSmoke.ps1 -Action Block -Key $k -GatewayBaseUrl $gw -KeyVaultName $kvn }
   & .\scripts\Test-PopeyeGatewayLockdown.ps1 -GatewayBaseUrl $gw -UserKey $r.Key   # positive control should now FAIL: the key is refused
   Remove-Variable dsn,r,x,f -ErrorAction SilentlyContinue
   Clear-History; Remove-Item (Get-PSReadLineOption).HistorySavePath -ErrorAction SilentlyContinue
   ```

   The plan also asks for `/key/info` showing `blocked: true`. That requires sending the key in a URL, so the "refused" result above is the safer proof. If the `/key/info` line is wanted anyway, query it by key hash, never by the plain key.

2. Sign out of Windows (**Start** → account → **Sign out**). Note the session end time.

3. On the workstation, remove the grants and confirm they're gone:

   ```powershell
   foreach ($s in 'litellm-master-key','litellm-database-url','litellm-reader-dsn') {
     az role assignment delete --assignee $oid --role "Key Vault Secrets User" --scope "$kv/secrets/$s"
     az role assignment list --assignee $oid --scope "$kv/secrets/$s" -o tsv }     # each must be empty
   (Get-Date).ToUniversalTime()   # T1
   ```

4. Record the Key Vault audit trail in the portal, with the query and row counts only:

   ```kusto
   AzureDiagnostics | where Category == "AuditEvent" and OperationName == "SecretGet"
   | where TimeGenerated between (datetime(<T0>) .. datetime(<T1>)) | summarize count() by id_s
   ```

   Keep `litellm-reader-dsn` readable afterwards if operators still need it, as procedure step 7 allows.

## Results to hand back for the evidence file

Bring back:

- T0 and T1, and the Bastion session window;
- the PASS or FAIL result of each step;
- the request ID from step 5 and the first 8 characters of the key hash;
- the budget-probe histogram;
- replica labels and per-replica counts, and the before and after Redis key-name counts;
- the NET-04 rows and the method used in step 8.6.

These feed `artifacts/popeye-mvp-smoke-evidence-2026-10-22.md` (01-08 Task 3) and the 01-08 summary. **Never record the master key, any smoke key, any DSN, prompt or response text, or any Entra object ID beyond its first 8 characters.**
