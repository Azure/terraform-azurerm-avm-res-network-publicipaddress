variable "enable_telemetry" {
  type        = bool
  default     = true
  description = <<DESCRIPTION
This variable controls whether or not telemetry is enabled for the module.
For more information see https://aka.ms/avm/telemetryinfo.
If it is set to false, then no telemetry will be collected.
DESCRIPTION
}

variable "rg_location" {
  type        = string
  default     = "eastus"
  description = <<DESCRIPTION
This variable defines the Azure region where the resource group will be created.
The default value is "eastus".
DESCRIPTION
}

variable "location" {
  type        = string
  default     = "eastus"
  description = <<DESCRIPTION
This variable defines the Azure region where the resource will be created.
The default value is "eastus".
DESCRIPTION
}

terraform {
  required_version = ">= 1.0.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
}

module "naming" {
  source  = "Azure/naming/azurerm"
  version = "0.4.0"
}

# This is required for resource modules
resource "azurerm_resource_group" "this" {
  location = var.rg_location
  name     = module.naming.resource_group.name_unique
}

# This is the module call
module "public_ip_address" {
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

output "created_resource" {
  value = module.public_ip_address.public_ip_id
}
output "assigned_ip_address" {
  value = module.public_ip_address.public_ip_address
}
