# modules/gateway-observability-azure
# Observability tier per roadmap section 7: workspace, app insights,
# diagnostic settings, action group, and the alerting baseline (7.3).
#
# Design rule (roadmap 4.1): nothing in this module is in the request
# path. It observes; it cannot block.

resource "azurerm_log_analytics_workspace" "gateway" {
  name                = "${var.name_prefix}-law"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days
  tags                = var.tags
}

resource "azurerm_application_insights" "gateway" {
  name                = "${var.name_prefix}-appi"
  location            = var.location
  resource_group_name = var.resource_group_name
  workspace_id        = azurerm_log_analytics_workspace.gateway.id
  application_type    = "other"
  tags                = var.tags
}

# Ship Postgres (ledger) diagnostics: ledger write failures are a
# page-level alert (roadmap 7.3).
resource "azurerm_monitor_diagnostic_setting" "postgres" {
  name                       = "${var.name_prefix}-pg-diag"
  target_resource_id         = var.postgres_server_id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.gateway.id

  enabled_log {
    category = "PostgreSQLLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

# Notify channel: Teams via webhook (O365-native, roadmap 7.3).
resource "azurerm_monitor_action_group" "notify" {
  count = var.teams_webhook_url == "" ? 0 : 1

  name                = "${var.name_prefix}-notify"
  resource_group_name = var.resource_group_name
  short_name          = "popeye"

  webhook_receiver {
    name                    = "teams"
    service_uri             = var.teams_webhook_url
    use_common_alert_schema = true
  }

  tags = var.tags
}

# --- Alerting baseline (roadmap 7.3) ---------------------------------
# These page-level alerts are deliberately conservative POC guards that
# can fire before Stage 1 produces burn-rate thresholds. Budget
# threshold, spend-velocity, fallback-activation, nono-bypass, and
# attribution-completeness alerts remain deferred until
# specs/STAGE1_BASELINES.md supplies measured thresholds and data
# sources.

resource "azurerm_monitor_metric_alert" "gateway_failed_requests" {
  name                = "${var.name_prefix}-gateway-5xx"
  resource_group_name = var.resource_group_name
  scopes              = [var.container_app_id]
  description         = "PAGE: gateway returned 5xx responses. Conservative POC guard; burn-rate thresholds come from Stage 1 baselines."
  severity            = 1
  frequency           = "PT1M"
  window_size         = "PT5M"

  criteria {
    metric_namespace = "Microsoft.App/containerApps"
    metric_name      = "Requests"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = 0

    dimension {
      name     = "statusCodeCategory"
      operator = "Include"
      values   = ["5xx"]
    }
  }

  dynamic "action" {
    for_each = var.teams_webhook_url == "" ? [] : [azurerm_monitor_action_group.notify[0].id]

    content {
      action_group_id = action.value
    }
  }

  tags = var.tags
}

resource "azurerm_monitor_metric_alert" "gateway_replica_unavailable" {
  name                = "${var.name_prefix}-gateway-replicas-low"
  resource_group_name = var.resource_group_name
  scopes              = [var.container_app_id]
  description         = "PAGE: gateway active replicas below the minimum HA posture."
  severity            = 1
  frequency           = "PT1M"
  window_size         = "PT5M"

  criteria {
    metric_namespace = "Microsoft.App/containerApps"
    metric_name      = "Replicas"
    aggregation      = "Average"
    operator         = "LessThan"
    threshold        = 2
  }

  dynamic "action" {
    for_each = var.teams_webhook_url == "" ? [] : [azurerm_monitor_action_group.notify[0].id]

    content {
      action_group_id = action.value
    }
  }

  tags = var.tags
}

resource "azurerm_monitor_metric_alert" "postgres_availability" {
  name                = "${var.name_prefix}-postgres-unavailable"
  resource_group_name = var.resource_group_name
  scopes              = [var.postgres_server_id]
  description         = "PAGE: regional ledger Postgres availability metric reports unhealthy."
  severity            = 1
  frequency           = "PT1M"
  window_size         = "PT5M"

  criteria {
    metric_namespace = "Microsoft.DBforPostgreSQL/flexibleServers"
    metric_name      = "is_db_alive"
    aggregation      = "Average"
    operator         = "LessThan"
    threshold        = 1
  }

  dynamic "action" {
    for_each = var.teams_webhook_url == "" ? [] : [azurerm_monitor_action_group.notify[0].id]

    content {
      action_group_id = action.value
    }
  }

  tags = var.tags
}
