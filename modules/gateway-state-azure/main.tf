# modules/gateway-state-azure
# Gateway state tier: keys, budgets, and the regional spend ledger
# (Postgres) plus rate/budget counters and router state (Redis).
#
# Design rules carried from AI_USAGE_GOVERNANCE_ROADMAP_v0.2.md:
# - Dedicated instance. Never shared with application-domain databases
#   (section 4.2).
# - Ledger impairment must never block requests; HA here protects
#   enforcement state, not the request path (section 4.1).

resource "azurerm_postgresql_flexible_server" "gateway" {
  name                = var.postgres_server_name
  resource_group_name = var.resource_group_name
  location            = var.location
  zone                = "3"

  version                = "16"
  administrator_login    = var.postgres_admin_login
  administrator_password = var.postgres_admin_password

  sku_name   = var.postgres_sku_name
  storage_mb = var.postgres_storage_mb

  backup_retention_days         = 14
  public_network_access_enabled = false

  delegated_subnet_id = var.postgres_delegated_subnet_id
  private_dns_zone_id = var.postgres_private_dns_zone_id

  # Regional ledgers are sources of truth (infrastructure plan
  # section 4); zone-redundant HA is the availability posture, PITR
  # backups are the durability posture.
  high_availability {
    mode                      = "ZoneRedundant"
    standby_availability_zone = "1"
  }

  tags = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_postgresql_flexible_server_database" "litellm" {
  name      = "litellm"
  server_id = azurerm_postgresql_flexible_server.gateway.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

resource "azurerm_managed_redis" "gateway" {
  name                = var.redis_name
  location            = var.location
  resource_group_name = var.resource_group_name

  sku_name                  = var.managed_redis_sku_name
  high_availability_enabled = var.managed_redis_high_availability_enabled
  public_network_access     = var.managed_redis_public_network_access

  default_database {
    access_keys_authentication_enabled = true
    client_protocol                    = "Encrypted"
    eviction_policy                    = "NoEviction"
  }

  # Redis down => enforcement degrades toward permissive, requests
  # continue (roadmap 4.3). Azure Cache for Redis creation is blocked
  # in this subscription/region due retirement, so use Azure Managed
  # Redis for new POC deployments.

  tags = var.tags
}
