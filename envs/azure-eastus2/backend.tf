terraform {
  backend "azurerm" {
    resource_group_name  = "rg-popeye-tfstate-eastus2"
    storage_account_name = "popeyetfstate98c2b71b"
    container_name       = "popeye-infra"
    key                  = "azure-eastus2.tfstate"
    use_azuread_auth     = true
  }
}

# The state contains generated secrets (Postgres admin, master/salt
# keys). This backend is created before the first apply and uses Azure
# Storage encryption plus Entra-authenticated access.