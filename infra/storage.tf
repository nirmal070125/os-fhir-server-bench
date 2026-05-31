# Storage account names are globally unique + 3-24 lowercase alphanumerics, so
# suffix with a random string derived from this deployment.
resource "random_string" "sa" {
  length  = 10
  special = false
  upper   = false
}

resource "azurerm_storage_account" "results" {
  name                            = "fhirbench${random_string.sa.result}"
  resource_group_name             = azurerm_resource_group.rg.name
  location                        = azurerm_resource_group.rg.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  tags                            = local.tags
}

resource "azurerm_storage_container" "results" {
  name                  = local.cfg.reporting.blob_container
  storage_account_name  = azurerm_storage_account.results.name
  container_access_type = "private"
}
