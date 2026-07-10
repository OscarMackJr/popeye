output "postgres_fqdn" {
  value = azurerm_postgresql_flexible_server.gateway.fqdn
}

output "postgres_server_id" {
  value = azurerm_postgresql_flexible_server.gateway.id
}

output "litellm_database_name" {
  value = azurerm_postgresql_flexible_server_database.litellm.name
}

output "redis_hostname" {
  value = azurerm_managed_redis.gateway.hostname
}

output "redis_ssl_port" {
  value = azurerm_managed_redis.gateway.default_database[0].port
}

output "redis_primary_access_key" {
  value     = azurerm_managed_redis.gateway.default_database[0].primary_access_key
  sensitive = true
}

output "redis_id" {
  value = azurerm_managed_redis.gateway.id
}
