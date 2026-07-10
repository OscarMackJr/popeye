output "log_analytics_workspace_id" {
  value = azurerm_log_analytics_workspace.gateway.id
}

output "app_insights_connection_string" {
  value     = azurerm_application_insights.gateway.connection_string
  sensitive = true
}

output "action_group_id" {
  value = try(azurerm_monitor_action_group.notify[0].id, null)
}
