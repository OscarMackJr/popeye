variable "approvers_group_name" {
  type    = string
  default = "sg-ai-gateway-breakglass-approvers"
}

variable "key_vault_name" {
  description = "Globally unique Key Vault name for the dormant break-glass vault."
  type        = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "tenant_id" {
  type = string
}

variable "log_analytics_workspace_id" {
  description = "Workspace receiving the vault audit trail."
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "approvers_principal_id" {
  description = "Existing Entra principal object id granted access to the dormant break-glass vault. If empty, Terraform creates a group."
  type        = string
  default     = ""
}