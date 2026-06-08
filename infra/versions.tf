terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# Auth: no creds in code. Two modes, both via the standard azurerm discovery —
#   1. Service principal: ARM_SUBSCRIPTION_ID + ARM_TENANT_ID + ARM_CLIENT_ID + ARM_CLIENT_SECRET
#   2. Azure CLI: ARM_SUBSCRIPTION_ID + an `az login` session (no SP needed)
# azurerm v4 requires an explicit subscription, supplied by ARM_SUBSCRIPTION_ID.
provider "azurerm" {
  features {}
}
