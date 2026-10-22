variable "resource_group_name" {
  description = "Resource group for the gateway state tier."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "postgres_server_name" {
  description = "Name of the PostgreSQL Flexible Server holding keys, budgets, and the regional spend ledger."
  type        = string
}

variable "postgres_admin_login" {
  description = "Postgres administrator login (writer bootstrap; application roles are created by sql/ai_usage_grants.sql)."
  type        = string
}

variable "postgres_admin_password" {
  description = "Postgres administrator password. Supply from a random_password resource; never a literal."
  type        = string
  sensitive   = true
}

variable "postgres_sku_name" {
  description = "Flexible Server SKU. General Purpose minimum for HA; size after Stage 1 baseline load numbers."
  type        = string
  default     = "GP_Standard_D2ds_v5"
}

variable "postgres_storage_mb" {
  type    = number
  default = 65536
}

variable "postgres_delegated_subnet_id" {
  description = "Delegated subnet for Flexible Server VNet integration."
  type        = string
}

variable "postgres_private_dns_zone_id" {
  description = "Private DNS zone id (privatelink.postgres.database.azure.com) linked to the VNet."
  type        = string
}

variable "redis_name" {
  type = string
}

variable "managed_redis_sku_name" {
  description = "Azure Managed Redis SKU for new deployments; Azure Cache for Redis creation is blocked in this subscription."
  type        = string
  default     = "Balanced_B1"
}

variable "managed_redis_high_availability_enabled" {
  type    = bool
  default = true
}

variable "managed_redis_public_network_access" {
  description = "Redis public network access. The root sets Disabled once the private endpoint exists (D-16); module default stays Enabled so it is safe standalone."
  type        = string
  default     = "Enabled"

  validation {
    condition     = contains(["Enabled", "Disabled"], var.managed_redis_public_network_access)
    error_message = "managed_redis_public_network_access must be Enabled or Disabled."
  }
}

variable "redis_clustering_policy" {
  description = "Managed Redis clustering policy. NoCluster/EnterpriseCluster work with plain (non-cluster) clients such as LiteLLM's; OSSCluster does not (RESEARCH Pitfall 5)."
  type        = string
  default     = "NoCluster"

  validation {
    condition     = contains(["OSSCluster", "EnterpriseCluster", "NoCluster"], var.redis_clustering_policy)
    error_message = "redis_clustering_policy must be OSSCluster, EnterpriseCluster or NoCluster."
  }
}

variable "tags" {
  type    = map(string)
  default = {}
}
