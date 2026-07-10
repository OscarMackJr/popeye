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
  description = "Pinned LiteLLM -stable tag. No default on purpose."
  type        = string
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