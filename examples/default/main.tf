# This ensures we have unique CAF compliant names for our resources.
module "naming" {
  source  = "Azure/naming/azurerm"
  version = "0.4.0"
}

# This is required for resource modules.
#
# The resource group is created with `azapi_resource` rather than
# `azurerm_resource_group`: this module no longer depends on
# `hashicorp/azurerm`, and an example that pulled the provider back in just to
# build its own fixture would defeat the migration. `parent_id` is omitted --
# for a subscription-scoped type AzAPI defaults it to the provider's
# subscription.
resource "azapi_resource" "rg" {
  location               = var.rg_location
  name                   = module.naming.resource_group.name_unique
  type                   = "Microsoft.Resources/resourceGroups@2024-03-01"
  response_export_values = []
  tags                   = local.tags
}

# This is the module call
module "public_ip_address" {
  source = "../../"

  location = var.location
  name     = module.naming.public_ip.name_unique
  # Required. The module never constructs the parent scope (TFRMFR1).
  parent_id        = azapi_resource.rg.id
  enable_telemetry = var.enable_telemetry
  # Exercises `azapi_resource_action.tags`, the replace-the-whole-set tag
  # writer that this module uses in place of the merge writer.
  tags = local.tags
}

locals {
  tags = {
    scenario = "default"
  }
}
