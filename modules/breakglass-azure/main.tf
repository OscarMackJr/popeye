# modules/breakglass-azure
# Standing break-glass capability, dormant by design (roadmap 8.3,
# infrastructure plan section 5): pre-created audited resources so an
# incident activates existing controls instead of hand-creating
# credentials at 2 AM.
#
# Dormancy model on Azure: a dedicated Key Vault whose ONLY data-plane
# readers are the approvers group. The secret holds a placeholder until
# an activation (dual-approved, per the runbook) writes a real,
# short-lived provider credential into it. Every read and write is in
# the vault audit log.

resource "azuread_group" "breakglass_approvers" {
  count = var.approvers_principal_id == "" ? 1 : 0

  display_name     = var.approvers_group_name
  security_enabled = true

  # Membership is deliberately NOT managed here: named individuals are
  # an operational decision (roadmap section 11), assigned via Entra
  # with PIM/eligible membership if available.
  lifecycle {
    ignore_changes = [members]
  }
}

resource "azurerm_key_vault" "breakglass" {
  name                = var.key_vault_name
  location            = var.location
  resource_group_name = var.resource_group_name
  tenant_id           = var.tenant_id
  sku_name            = "standard"

  rbac_authorization_enabled = true
  purge_protection_enabled   = true
  soft_delete_retention_days = 90

  tags = var.tags
}

# The ONLY data-plane grant on this vault.
resource "azurerm_role_assignment" "approvers_secrets" {
  scope                = azurerm_key_vault.breakglass.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = var.approvers_principal_id == "" ? azuread_group.breakglass_approvers[0].object_id : var.approvers_principal_id
}

# Vault audit trail to the gateway workspace: activations are visible
# in the same pane as the incident that caused them.
resource "azurerm_monitor_diagnostic_setting" "breakglass_audit" {
  name                       = "breakglass-audit"
  target_resource_id         = azurerm_key_vault.breakglass.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "AuditEvent"
  }
}

resource "azurerm_key_vault_secret" "provider_credential" {
  name         = "breakglass-provider-credential"
  key_vault_id = azurerm_key_vault.breakglass.id

  value = "DORMANT - populated only during an activated break-glass event; see roadmap 8.3"

  # Expiry forces the time-box: an activation must set a new short
  # expiration; the placeholder carries none and is inert.

  content_type = "break-glass placeholder"

  depends_on = [azurerm_role_assignment.approvers_secrets]

  lifecycle {
    # Activations happen out-of-band during incidents; Terraform must
    # not revert an active credential mid-incident.
    ignore_changes = [value, expiration_date]
  }

  tags = var.tags
}
