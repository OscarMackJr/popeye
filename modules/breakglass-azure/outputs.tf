output "approvers_group_object_id" {
  value = var.approvers_principal_id == "" ? azuread_group.breakglass_approvers[0].object_id : var.approvers_principal_id
}

output "breakglass_vault_id" {
  value = azurerm_key_vault.breakglass.id
}
