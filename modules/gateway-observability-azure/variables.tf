variable "name_prefix" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "postgres_server_id" {
  type = string
}

variable "container_app_id" {
  type = string
}

variable "teams_webhook_url" {
  description = "Teams incoming-webhook URL for the notify channel (roadmap 7.3)."
  type        = string
  sensitive   = true
}

variable "log_retention_days" {
  description = "Access/audit log retention. Audit-trail needs feed the Stage 2 OSS-vs-Enterprise ADR."
  type        = number
  default     = 90
}

variable "tags" {
  type    = map(string)
  default = {}
}
