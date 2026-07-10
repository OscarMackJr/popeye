output "gateway_internal_fqdn" {
  description = "Point gateway-azure.ai.twg.internal at this."
  value       = module.service.gateway_fqdn
}

output "postgres_fqdn" {
  value = module.state.postgres_fqdn
}

output "breakglass_vault_id" {
  value = module.breakglass.breakglass_vault_id
}

output "breakglass_approvers_group_object_id" {
  description = "Assign named approvers to this Entra group (roadmap section 11 open decision)."
  value       = module.breakglass.approvers_group_object_id
}

output "log_analytics_workspace_id" {
  value = module.observability.log_analytics_workspace_id
}
