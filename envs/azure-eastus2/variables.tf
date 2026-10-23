variable "environment" {
  description = "Environment name used in resource naming (e.g. stage2, prod)."
  type        = string
  default     = "stage2"
}

variable "location" {
  type    = string
  default = "eastus2"
}

variable "litellm_image_tag" {
  description = "Pinned LiteLLM tag, plain vX.Y.Z. Never latest, never the affected 1.91.0-1.100.3 range. No default on purpose; set in litellm-pin.auto.tfvars."
  type        = string
}

variable "litellm_image_digest" {
  description = "OCI digest (sha256:<64 hex>) of the pinned LiteLLM image. No default on purpose; set in litellm-pin.auto.tfvars."
  type        = string

  validation {
    condition     = can(regex("^sha256:[0-9a-f]{64}$", var.litellm_image_digest))
    error_message = "litellm_image_digest must match ^sha256:[0-9a-f]{64}$."
  }
}

variable "vnet_cidr" {
  type    = string
  default = "10.60.0.0/22"
}

variable "containerapps_subnet_cidr" {
  description = "Container Apps environment subnet (minimum /23 for workload profiles; confirm sizing)."
  type        = string
  default     = "10.60.0.0/23"
}

variable "postgres_subnet_cidr" {
  type    = string
  default = "10.60.2.0/24"
}

variable "private_endpoints_subnet_cidr" {
  description = "Non-delegated subnet for private endpoints (snet-private-endpoints), D-15."
  type        = string
  default     = "10.60.3.0/27"
}

variable "redis_public_network_access" {
  description = "Managed Redis public network access. Disabled by default (GW-06); apply once with Enabled for stage A (D-16)."
  type        = string
  default     = "Disabled"

  validation {
    condition     = contains(["Enabled", "Disabled"], var.redis_public_network_access)
    error_message = "redis_public_network_access must be Enabled or Disabled."
  }
}

variable "redis_clustering_policy" {
  description = "Managed Redis clustering policy; NoCluster for plain clients, EnterpriseCluster is the documented fallback."
  type        = string
  default     = "NoCluster"
}

variable "gateway_key_vault_name" {
  description = "Globally unique name for the gateway secrets vault."
  type        = string
}

variable "breakglass_key_vault_name" {
  description = "Globally unique name for the dormant break-glass vault."
  type        = string
}

variable "postgres_admin_login" {
  type    = string
  default = "litellm_admin"
}

variable "foundry_scope_id" {
  description = "Foundry / Azure OpenAI account resource id for managed-identity RBAC. Empty skips the assignment."
  type        = string
  default     = ""
}
variable "foundry_deployment_name" {
  description = "Azure Foundry / Azure OpenAI deployment name exposed through LiteLLM as twg-foundry."
  type        = string

  validation {
    condition     = length(trimspace(var.foundry_deployment_name)) > 0
    error_message = "Set the selected Foundry deployment name for the twg-foundry LiteLLM backend."
  }
}

variable "foundry_api_base" {
  description = "Base URL for the selected Foundry / Azure OpenAI endpoint, for example https://account.openai.azure.com/."
  type        = string

  validation {
    condition     = can(regex("^https://", var.foundry_api_base))
    error_message = "Foundry API base must be an HTTPS URL."
  }
}

variable "foundry_api_version" {
  description = "Azure OpenAI API version used by LiteLLM for the selected Foundry deployment."
  type        = string

  validation {
    condition     = length(trimspace(var.foundry_api_version)) > 0
    error_message = "Set the Azure OpenAI API version for the twg-foundry LiteLLM backend."
  }
}

variable "teams_webhook_url" {
  description = "Teams incoming webhook for the notify action group."
  type        = string
  sensitive   = true
  default     = ""
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "breakglass_approvers_principal_id" {
  description = "Existing Entra principal object id allowed to read/write the dormant break-glass vault for POC. Use a group in production."
  type        = string
  default     = ""
}
variable "manage_env_dns_zone" {
  description = "Set true only if networking hands ownership of the Container Apps environment private DNS zone to Popeye (D-14). Default false: networking owns it."
  type        = bool
  default     = false
}

variable "caller_vnet_id" {
  description = "Resource id of the caller VNet (EUS-POPEYE-VNET-01). Empty skips the caller link. Real value goes in gitignored terraform.tfvars only."
  type        = string
  default     = ""

  validation {
    condition     = var.caller_vnet_id == "" || can(regex("^/subscriptions/[0-9a-f-]{36}/resourcegroups/[^/]+/providers/microsoft.network/virtualnetworks/[^/]+$", lower(var.caller_vnet_id)))
    error_message = "caller_vnet_id must be empty or a virtualNetworks resource id."
  }
}
