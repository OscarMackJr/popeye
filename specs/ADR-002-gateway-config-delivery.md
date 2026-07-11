# ADR-002: Gateway Config Delivery

Status: Accepted
Date: 2026-07-10

## Context

The Azure eastus2 gateway runs LiteLLM in Azure Container Apps. The initial implementation booted with a minimal Terraform-injected config so the container could start before a pilot Foundry deployment was selected.

The open decision was whether to bake `litellm.azure.yaml` into an internal image or mount it as a file. The current operational need is smaller: deliver non-secret routing config for one `twg-foundry` backend while keeping provider credentials out of source control, application config, and Terraform variables.

## Decision

For Stage 2, Terraform renders the LiteLLM YAML from non-secret root module variables and delivers it as an Azure Container Apps secret. At container startup, the entrypoint writes that secret value to `/tmp/litellm.yaml` and starts LiteLLM with `--config`.

The rendered config includes:

- public LiteLLM model name: `twg-foundry`
- Foundry deployment name
- Foundry API base URL
- Foundry API version
- Redis, database, and master-key references through environment variables
- `store_prompts_in_spend_logs: false`

It must not include provider API keys or other provider credentials. Foundry access remains managed identity plus RBAC (`Cognitive Services OpenAI User`) wherever supported. If a temporary API-key fallback is needed, it must be delivered through Key Vault and documented as an exception, not embedded in the config YAML.

## Consequences

Config changes are Terraform changes and create a new Container Apps revision, which gives the Stage 2 deployment an auditable rollback path without building an internal image pipeline yet.

The rendered YAML is stored in Terraform state because Container Apps secret values are part of the managed resource. This is acceptable only because the YAML contains routing metadata, not secrets. The remote state backend remains sensitive and access-controlled because it also contains generated gateway and database secrets from other resources.

This decision can be revisited before production if config size, promotion workflow, or audit requirements justify an internal image or mounted file. Until then, this repo's Azure root module is the source of truth for the managed `twg-foundry` backend config.