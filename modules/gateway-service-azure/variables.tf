variable "name_prefix" {
  description = "Prefix for gateway service resources, e.g. gateway-azure-eastus2."
  type        = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "litellm_image_tag" {
  description = "Pinned LiteLLM image tag. A specific -stable release; never latest (Tier-0 posture, March 2026 supply-chain lesson)."
  type        = string

  validation {
    condition     = var.litellm_image_tag != "latest" && var.litellm_image_tag != ""
    error_message = "Pin a specific LiteLLM -stable tag. Never latest."
  }
}

variable "infrastructure_subnet_id" {
  description = "Subnet for the Container Apps environment."
  type        = string
}

variable "log_analytics_workspace_id" {
  type = string
}

variable "key_vault_id" {
  description = "Key Vault holding gateway secrets; the gateway identity gets Secrets User on this scope."
  type        = string
}

variable "master_key_secret_id" {
  description = "Key Vault secret id for LITELLM_MASTER_KEY."
  type        = string
}

variable "salt_key_secret_id" {
  description = "Key Vault secret id for LITELLM_SALT_KEY. Never rotated casually: rotation invalidates stored provider credentials (roadmap 8.2, runbook 4)."
  type        = string
}

variable "database_url_secret_id" {
  description = "Key Vault secret id for the litellm writer DATABASE_URL."
  type        = string
}

variable "redis_hostname" {
  type = string
}

variable "redis_ssl_port" {
  type = number
}

variable "redis_password_secret_id" {
  description = "Key Vault secret id for the Redis access key."
  type        = string
}

variable "foundry_scope_id" {
  description = "Resource id of the Foundry / Azure OpenAI account for managed-identity data-plane RBAC. Empty string skips the role assignment."
  type        = string
  default     = ""
}

variable "min_replicas" {
  description = "Minimum 2: stateless replicas across zones; capacity, not correctness (roadmap 4.2)."
  type        = number
  default     = 2

  validation {
    condition     = var.min_replicas >= 2
    error_message = "The gateway runs at least 2 replicas (roadmap 4.2)."
  }
}

variable "max_replicas" {
  type    = number
  default = 6
}

variable "container_cpu" {
  type    = number
  default = 1.0
}

variable "container_memory" {
  type    = string
  default = "2Gi"
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "litellm_config_yaml" {
  description = "LiteLLM config delivered as a Container Apps secret. Must contain no provider API keys because this value is present in Terraform state."
  type        = string
}