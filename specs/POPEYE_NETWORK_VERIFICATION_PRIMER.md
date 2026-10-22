# Popeye network verification: meeting primer

## The problem in plain English

Popeye is an internal AI-gateway project. One part of its non-production environment needs to use an existing PostgreSQL database. The database is deliberately not reachable from the public internet: it accepts connections only through Azure private networking.

Before relying on that arrangement, we want a small temporary Windows VM inside the same Azure virtual network. It gives the team a controlled place to prove that a normal internal workload can find the database by name and reach its PostgreSQL port, without opening the database to the internet or giving people broad secret access.

This is a connectivity and access-control check, not a request to change the database application or make it public.

## What the network engineer needs to do

1. Create a new, isolated VM subnet in the existing Popeye VNet. It must not be delegated to another Azure service.
2. Provision a temporary Windows Server 2022 VM in that subnet. The VM must have **no public IP address**.
3. Make VM administration available through Azure Bastion only. Direct public RDP to the VM must not be possible.
4. Give only the two approved users access through Entra ID and Azure RBAC. This means access belongs to named people, not to everyone in the resource group and not to the VM identity.
5. Check that the existing PostgreSQL private DNS zone is usable from this VNet. The VM must resolve the normal database name to a private address such as `10.x.x.x`, not to a public internet address.
6. Check the network rules. The VM needs only outbound TCP port 5432 to the existing PostgreSQL private endpoint. Do not enable public database access.
7. Make only the minimum DNS, routing, or NSG changes needed. Existing PostgreSQL and Terraform-managed DNS resources should not be changed without coordinating with the Popeye Terraform owner.

## What success looks like

From a Bastion session on the temporary VM, these commands should succeed:

```powershell
Resolve-DnsName pg-popeye-stage1-stage2-eastus2.postgres.database.azure.com
Test-NetConnection pg-popeye-stage1-stage2-eastus2.postgres.database.azure.com -Port 5432
```

The DNS command must return a private RFC1918 address (`10.0.0.0/8`, `172.16.0.0/12`, or `192.168.0.0/16`). The TCP test must report success on port 5432.

After the database team has created and checked a read-only database account, the operators can also use a dedicated read-only connection secret to run a harmless `SELECT 1` test with `psql`. They must not receive the gateway's writer, master, salt, or general database connection secrets.

## Why the constraints matter

- **No VM public IP and Bastion-only access:** reduces the attack surface for a temporary administration VM.
- **Private DNS:** ensures the familiar database hostname points to the private endpoint, rather than bypassing the intended network path.
- **TCP 5432 only:** demonstrates the one required database path without opening unnecessary ports.
- **Named-user access:** makes access reviewable and removable when the POC ends.
- **Temporary lifetime:** the VM should be shut down outside the test window and removed by the agreed review date unless an extension is approved.
