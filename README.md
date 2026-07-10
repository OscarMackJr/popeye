# Popeye (ai-gateway-infra)


Project codename: **Popeye** — TWG's AI usage governance control plane.
Infrastructure for TWG's AI usage governance control plane: the AI
gateway (enforcement), endpoint automation (desktop coverage), and the
supporting state, observability, and break-glass resources.

The reporting tier (`ai_token_usage` Cube model) lives in the hometown
Enterprise Knowledge Graph repository; this repo deploys everything
that feeds it.

## Orientation

Read in order:

1. [STATE.md](./STATE.md) — where the project is and the next task.
2. [specs/AI_USAGE_GOVERNANCE_ROADMAP_v0.2.md](./specs/AI_USAGE_GOVERNANCE_ROADMAP_v0.2.md) — the why and the reliability model.
3. [specs/GATEWAY_INFRASTRUCTURE_PLAN_v0.1.md](./specs/GATEWAY_INFRASTRUCTURE_PLAN_v0.1.md) — the what and the how.
4. [specs/ROADMAP_integration_popeye.md](./specs/ROADMAP_integration_popeye.md) — the working scope and MVP boundary.

## Layout

```
specs/       Design artifacts and (future) ADRs
modules/     Terraform modules (Azure implemented; reporting stubbed)
envs/        Root modules per environment
  azure-eastus2/   Stage 2: first managed regional gateway (implemented)
  aws-use1/        Stage 3: second region (stub; starts from the
                   BerriAI/litellm/aws registry module, forked)
  reporting/       Stage 3: consolidated reporting stack (stub)
config/      Per-region gateway configuration (examples committed;
             filled copies never committed)
scripts/     Entra/Intune PowerShell automation (not Terraform on purpose)
sql/         Ledger bootstrap and read-only grants
```

## First Apply (Stage 2, azure-eastus2)

```bash
cd envs/azure-eastus2
cp terraform.tfvars.example terraform.tfvars   # fill in; not committed
# Configure the state backend FIRST (backend.tf) — state holds secrets.
terraform init
terraform plan
```

Hard rules, enforced structurally where possible:

- `litellm_image_tag` has no default and rejects `latest` (validation).
- `min_replicas` rejects values under 2 (validation).
- The salt key has `prevent_destroy` and ignored value drift; rotating
  it is an incident-class action (roadmap 8.2, runbook 4).
- Break-glass vault is dormant: approvers-only data plane, audited,
  placeholder secret until a dual-approved activation.
- Filled config and tfvars are gitignored; examples are committed.
