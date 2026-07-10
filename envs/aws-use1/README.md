# envs/aws-use1 (Stage 3)

Second regional gateway: gateway-aws fronting Bedrock from us-east-1.

Deliberately a stub until Stage 3 (infrastructure plan section 8).
Azure led Stage 2 because TWG's identity estate (Entra, Intune,
Key Vault) is Azure-native and no vendor module exists there; the AWS
side has a published accelerator to start from:

- Terraform Registry: `BerriAI/litellm/aws` (ECS Fargate + ALB + RDS +
  Redis reference stack). Evaluate, fork, and bring under this repo's
  module conventions rather than consuming it blind — it is a starting
  point, not a dependency.

Requirements this env must satisfy when built (infra plan section 2):

- ECS Fargate service, pinned image, 2+ tasks across AZs, internal ALB.
- IAM task role with bedrock:InvokeModel / InvokeModelWithResponseStream
  scoped to approved model ARNs. No long-lived AWS access keys.
- Multi-AZ RDS Postgres (regional ledger) + ElastiCache Redis.
- Secrets Manager for master/salt keys; salt-key rotation is
  incident-class only (roadmap 8.2 runbook 4).
- Application inference profiles per onboarded app, cost-allocation
  tagged (feeds the 7.4 monthly bill-versus-ledger spot check).
- Route 53 internal record gateway-aws.ai.twg.internal.
- Break-glass: pre-created DISABLED IAM role assumable only by the
  approvers group; mirrors modules/breakglass-azure semantics.
