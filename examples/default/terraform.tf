terraform {
  required_version = "~> 1.9"

  required_providers {
    # Used directly by `azapi_resource.rg`, and the same constraint the module
    # under test declares, so the example resolves one provider version.
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.12"
    }
  }
}

provider "azapi" {}
