# envs/azure-eastus2
# First managed regional gateway: gateway-azure (Stage 2).
# Wires networking, Key Vault, and the four modules together.

locals {
  name_prefix = "popeye-${var.environment}-eastus2"
  tags = merge(var.tags, {
    project     = "popeye"
    environment = var.environment
    region      = "eastus2"
    managed_by  = "terraform"
    spec        = "AI_USAGE_GOVERNANCE_ROADMAP_v0.2"
  })
  # Public model names rendered here must correspond to reviewed entries in
  # config/model-approval-registry.example.yaml. Key allowlists are derived
  # from that registry; this YAML remains provider routing config only.
  litellm_config_yaml = <<-EOT
model_list:
  - model_name: twg-foundry
    litellm_params:
      model: azure/${var.foundry_deployment_name}
      api_base: ${var.foundry_api_base}
      api_version: ${var.foundry_api_version}

router_settings:
  num_retries: 2
  timeout: 120
  redis_host: os.environ/REDIS_HOST
  redis_port: os.environ/REDIS_PORT
  redis_password: os.environ/REDIS_PASSWORD

litellm_settings:
  store_prompts_in_spend_logs: false

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
  database_url: os.environ/DATABASE_URL
EOT
}

data "azurerm_client_config" "current" {}

# --- Networking ------------------------------------------------------

resource "azurerm_resource_group" "gateway" {
  name     = "rg-${local.name_prefix}"
  location = var.location
  tags     = local.tags
}

resource "azurerm_virtual_network" "gateway" {
  name                = "vnet-${local.name_prefix}"
  location            = var.location
  resource_group_name = azurerm_resource_group.gateway.name
  address_space       = [var.vnet_cidr]
  tags                = local.tags

  # TODO(stage-2): peer to the application VNet(s); ingress is limited
  # to application subnets and the desktop path (infra plan section 3).
}

resource "azurerm_subnet" "containerapps" {
  name                 = "snet-containerapps"
  resource_group_name  = azurerm_resource_group.gateway.name
  virtual_network_name = azurerm_virtual_network.gateway.name
  address_prefixes     = [var.containerapps_subnet_cidr]

  delegation {
    name = "container-apps"

    service_delegation {
      name = "Microsoft.App/environments"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
      ]
    }
  }
}

resource "azurerm_subnet" "postgres" {
  name                 = "snet-postgres"
  resource_group_name  = azurerm_resource_group.gateway.name
  virtual_network_name = azurerm_virtual_network.gateway.name
  address_prefixes     = [var.postgres_subnet_cidr]
  service_endpoints    = ["Microsoft.Storage"]

  delegation {
    name = "postgres-flexible"

    service_delegation {
      name = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
      ]
    }
  }
}

resource "azurerm_private_dns_zone" "postgres" {
  name                = "privatelink.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.gateway.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "postgres" {
  name                  = "pg-vnet-link"
  resource_group_name   = azurerm_resource_group.gateway.name
  private_dns_zone_name = azurerm_private_dns_zone.postgres.name
  virtual_network_id    = azurerm_virtual_network.gateway.id
}

# --- Gateway secrets vault -------------------------------------------
# Distinct from the break-glass vault (different readers, different
# purpose). Holds master key, salt key, database URL.

resource "azurerm_key_vault" "gateway" {
  name                = var.gateway_key_vault_name
  location            = var.location
  resource_group_name = azurerm_resource_group.gateway.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  rbac_authorization_enabled = true
  purge_protection_enabled   = true
  soft_delete_retention_days = 90

  tags = local.tags
}

# Terraform's own identity needs to write the generated secrets.
resource "azurerm_role_assignment" "deployer_secrets_officer" {
  scope                = azurerm_key_vault.gateway.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Generated once, stored only in Key Vault and state (state backend
# must be encrypted + access-controlled; see backend.tf).
resource "random_password" "postgres_admin" {
  length  = 32
  special = false
}

resource "random_password" "litellm_master_key" {
  length  = 48
  special = false
}

resource "random_password" "litellm_salt_key" {
  length  = 48
  special = false
}

resource "azurerm_key_vault_secret" "master_key" {
  name         = "litellm-master-key"
  key_vault_id = azurerm_key_vault.gateway.id
  value        = "sk-${random_password.litellm_master_key.result}"
  depends_on   = [azurerm_role_assignment.deployer_secrets_officer]
}

resource "azurerm_key_vault_secret" "salt_key" {
  name         = "litellm-salt-key"
  key_vault_id = azurerm_key_vault.gateway.id
  value        = random_password.litellm_salt_key.result
  depends_on   = [azurerm_role_assignment.deployer_secrets_officer]

  lifecycle {
    # Roadmap 8.2 runbook 4: salt-key rotation invalidates stored
    # provider credentials. Never rotate via a casual apply.
    prevent_destroy = true
    ignore_changes  = [value]
  }
}

resource "azurerm_key_vault_secret" "database_url" {
  name         = "litellm-database-url"
  key_vault_id = azurerm_key_vault.gateway.id
  value = format(
    "postgresql://%s:%s@%s:5432/%s",
    var.postgres_admin_login,
    random_password.postgres_admin.result,
    module.state.postgres_fqdn,
    module.state.litellm_database_name,
  )
  depends_on = [azurerm_role_assignment.deployer_secrets_officer]
}
resource "azurerm_key_vault_secret" "redis_password" {
  name         = "redis-password"
  key_vault_id = azurerm_key_vault.gateway.id
  value        = module.state.redis_primary_access_key
  depends_on   = [azurerm_role_assignment.deployer_secrets_officer]
}

# --- Modules ---------------------------------------------------------

module "state" {
  source = "../../modules/gateway-state-azure"

  resource_group_name          = azurerm_resource_group.gateway.name
  location                     = var.location
  postgres_server_name         = "pg-${local.name_prefix}"
  postgres_admin_login         = var.postgres_admin_login
  postgres_admin_password      = random_password.postgres_admin.result
  postgres_delegated_subnet_id = azurerm_subnet.postgres.id
  postgres_private_dns_zone_id = azurerm_private_dns_zone.postgres.id
  redis_name                   = "redis-${local.name_prefix}"
  tags                         = local.tags

  depends_on = [azurerm_private_dns_zone_virtual_network_link.postgres]
}

module "observability" {
  source = "../../modules/gateway-observability-azure"

  name_prefix         = local.name_prefix
  resource_group_name = azurerm_resource_group.gateway.name
  location            = var.location
  postgres_server_id  = module.state.postgres_server_id
  container_app_id    = module.service.container_app_id
  teams_webhook_url   = var.teams_webhook_url
  tags                = local.tags
}

module "service" {
  source = "../../modules/gateway-service-azure"

  name_prefix                = local.name_prefix
  resource_group_name        = azurerm_resource_group.gateway.name
  location                   = var.location
  litellm_image_tag          = var.litellm_image_tag
  infrastructure_subnet_id   = azurerm_subnet.containerapps.id
  log_analytics_workspace_id = module.observability.log_analytics_workspace_id
  key_vault_id               = azurerm_key_vault.gateway.id
  master_key_secret_id       = azurerm_key_vault_secret.master_key.id
  salt_key_secret_id         = azurerm_key_vault_secret.salt_key.id
  database_url_secret_id     = azurerm_key_vault_secret.database_url.id
  redis_hostname             = module.state.redis_hostname
  redis_ssl_port             = module.state.redis_ssl_port
  redis_password_secret_id   = azurerm_key_vault_secret.redis_password.id
  foundry_scope_id           = var.foundry_scope_id
  litellm_config_yaml        = local.litellm_config_yaml
  tags                       = local.tags
}

module "breakglass" {
  source = "../../modules/breakglass-azure"

  key_vault_name             = var.breakglass_key_vault_name
  resource_group_name        = azurerm_resource_group.gateway.name
  location                   = var.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  log_analytics_workspace_id = module.observability.log_analytics_workspace_id
  approvers_principal_id     = var.breakglass_approvers_principal_id
  tags                       = local.tags
}

# --- Internal DNS ----------------------------------------------------
# gateway-azure.ai.twg.internal -> Container App internal FQDN.
# TODO(stage-2, decision due 2026-08-15): central networking either
# owns and creates/delegates this record, or this stack gains the
# private DNS zone variables/data sources needed to manage it here.
