# This ensures we have unique CAF compliant names for our resources.
module "naming" {
  source  = "Azure/naming/azurerm"
  version = "0.4.0"
}

# This is required for resource modules
resource "azurerm_resource_group" "this" {
  name     = module.naming.resource_group.name_unique
  location = var.rg_location
}

# This is the module call
module "PublicIPAddress" {
  source = "../../"
  # source             = "Azure/avm-<res/ptn>-<name>/azurerm"
  enable_telemetry    = var.enable_telemetry
  resource_group_name = azurerm_resource_group.this.name
  name                = module.naming.public_ip.name_unique
  location            = var.location
  #allocation_method = var.allocation_method
  #sku = var.sku
  #zones = var.zones
  #ip_version = var.ip_version
  #domain_name_label = var.domain_name_label
  #reverse_fqdn = var.reverse_fqdn
  #tags = var.tags
  #public_ip_prefix_id = var.public_ip_prefix_id
  #idle_timeout_in_minutes = var.idle_timeout_in_minutes
  #ip_tags = var.ip_tags
  #sku_tier = var.sku_tier
  #ddos_protection_mode = var.ddos_protection_mode
  #ddos_protection_plan_id = var.ddos_protection_plan_id
  #edge_zone = var.edge_zone
}

