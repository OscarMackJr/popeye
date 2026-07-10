output "gateway_fqdn" {
  description = "Internal FQDN of the gateway app; target for the gateway-azure.ai.twg.internal DNS record."
  value       = azurerm_container_app.gateway.ingress[0].fqdn
}

output "gateway_identity_principal_id" {
  value = azurerm_user_assigned_identity.gateway.principal_id
}

output "container_app_id" {
  value = azurerm_container_app.gateway.id
}

output "container_app_environment_id" {
  value = azurerm_container_app_environment.gateway.id
}
