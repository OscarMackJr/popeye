# State Backend Access Confirmation

Version: 0.1
Status: Draft confirmation record
Date: 2026-08-01
Audience: popeye maintainers, reviewers, POC lead

## Backend

Azure eastus2 Terraform state is configured in `envs/azure-eastus2/backend.tf`:

- resource group: `rg-popeye-tfstate-eastus2`
- storage account: `popeyetfstate98c2b71b`
- container: `popeye-infra`
- key: `azure-eastus2.tfstate`
- authentication: Entra ID (`use_azuread_auth = true`)

## Sensitivity

The state file is sensitive infrastructure data. It contains generated or provider-returned secrets, including:

- Postgres administrator password
- LiteLLM master key
- LiteLLM salt key
- database connection URL
- Redis access key material used to create the Key Vault secret

Runtime delivery now uses Key Vault references for master key, salt key, database URL, and Redis password. That improves the Container Apps posture, but it does not make Terraform state non-sensitive.

## Access Control

Required access model:

- Azure Storage encryption at rest remains enabled for the storage account.
- State read/write access is through Entra-authenticated Azure RBAC, not account-key sharing.
- State read/write is restricted to the deployment identity and named platform maintainers.
- Read-only access to state is treated as secret access.

Current owner placeholder: popeye platform owner / POC lead.

Before MVP exit, replace this placeholder with the named Entra group or managed identity assignments that hold state access.
