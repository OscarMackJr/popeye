# modules/gateway-service-azure
# Gateway request path: N stateless replicas of the pinned LiteLLM
# image on Azure Container Apps, internal ingress only, managed
# identity to Key Vault and Foundry.
#
# Design rules carried from the specs:
# - Image tag is pinned by variable with no default; latest is
#   structurally impossible (roadmap Tier-0 posture).
# - min_replicas >= 2: replica count is a capacity decision, not a
#   correctness decision (roadmap 4.2).
# - No provider API keys in configuration; Foundry auth is managed
#   identity RBAC, secrets arrive as Key Vault references
#   (infrastructure plan section 3).

resource "azurerm_user_assigned_identity" "gateway" {
  name                = "${var.name_prefix}-identity"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

# Read access to gateway secrets (master key, salt key, database URL).
resource "azurerm_role_assignment" "kv_secrets_user" {
  scope                = var.key_vault_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.gateway.principal_id
}

# Foundry data-plane access via RBAC instead of API keys, where the
# gateway supports Entra auth to the deployment. Optional: pass an
# empty string to skip while API-key auth is still in use.
resource "azurerm_role_assignment" "foundry_user" {
  count                = var.foundry_scope_id == "" ? 0 : 1
  scope                = var.foundry_scope_id
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = azurerm_user_assigned_identity.gateway.principal_id
}

resource "azurerm_container_app_environment" "gateway" {
  name                           = "${var.name_prefix}-env"
  location                       = var.location
  resource_group_name            = var.resource_group_name
  log_analytics_workspace_id     = var.log_analytics_workspace_id
  infrastructure_subnet_id       = var.infrastructure_subnet_id
  internal_load_balancer_enabled = true

  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
    minimum_count         = 0
    maximum_count         = 0
  }

  tags = var.tags
}

resource "azurerm_container_app" "gateway" {
  name                         = "${var.name_prefix}-app"
  container_app_environment_id = azurerm_container_app_environment.gateway.id
  resource_group_name          = var.resource_group_name
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.gateway.id]
  }

  ingress {
    external_enabled = false
    target_port      = 4000
    transport        = "auto"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  # Runtime credentials arrive as Key Vault references resolved by the
  # managed identity. The LiteLLM config secret is routing metadata
  # delivered as a Container Apps secret per ADR-002.
  secret {
    name                = "litellm-master-key"
    key_vault_secret_id = var.master_key_secret_id
    identity            = azurerm_user_assigned_identity.gateway.id
  }

  secret {
    name                = "litellm-salt-key"
    key_vault_secret_id = var.salt_key_secret_id
    identity            = azurerm_user_assigned_identity.gateway.id
  }

  secret {
    name                = "database-url"
    key_vault_secret_id = var.database_url_secret_id
    identity            = azurerm_user_assigned_identity.gateway.id
  }

  secret {
    name                = "redis-password"
    key_vault_secret_id = var.redis_password_secret_id
    identity            = azurerm_user_assigned_identity.gateway.id
  }

  secret {
    name  = "litellm-config"
    value = var.litellm_config_yaml
  }

  template {
    min_replicas = var.min_replicas
    max_replicas = var.max_replicas

    container {
      name = "litellm"

      # Pinned release tag only; enforced by variable validation.
      image = "ghcr.io/berriai/litellm:${var.litellm_image_tag}"

      command = ["/bin/sh", "-c"]
      args    = ["printf '%s' \"$LITELLM_CONFIG\" > /tmp/litellm.yaml && litellm --config /tmp/litellm.yaml --host 0.0.0.0 --port 4000"]

      cpu    = var.container_cpu
      memory = var.container_memory

      env {
        name        = "LITELLM_MASTER_KEY"
        secret_name = "litellm-master-key"
      }

      env {
        name        = "LITELLM_SALT_KEY"
        secret_name = "litellm-salt-key"
      }

      env {
        name        = "DATABASE_URL"
        secret_name = "database-url"
      }

      env {
        name  = "REDIS_HOST"
        value = var.redis_hostname
      }

      env {
        name  = "REDIS_PORT"
        value = tostring(var.redis_ssl_port)
      }

      env {
        name        = "REDIS_PASSWORD"
        secret_name = "redis-password"
      }

      env {
        name  = "REDIS_SSL"
        value = "true"
      }

      env {
        name        = "LITELLM_CONFIG"
        secret_name = "litellm-config"
      }

      env {
        name  = "AZURE_CLIENT_ID"
        value = azurerm_user_assigned_identity.gateway.client_id
      }

      # ADR-002: deploy the non-secret LiteLLM routing config as a
      # Container Apps secret and write it to disk at process startup.
      # Provider credentials stay in managed identity / Key Vault paths.

      startup_probe {
        transport               = "HTTP"
        port                    = 4000
        path                    = "/health/liveliness"
        initial_delay           = 10
        interval_seconds        = 10
        timeout                 = 3
        failure_count_threshold = 18
      }

      readiness_probe {
        transport               = "HTTP"
        port                    = 4000
        path                    = "/health/liveliness"
        interval_seconds        = 10
        timeout                 = 3
        failure_count_threshold = 3
        success_count_threshold = 1
      }

      liveness_probe {
        transport               = "HTTP"
        port                    = 4000
        path                    = "/health/liveliness"
        initial_delay           = 60
        interval_seconds        = 30
        timeout                 = 3
        failure_count_threshold = 3
      }
    }
  }

  tags = var.tags
}

