variable "enable_telemetry" {
  type        = bool
  default     = true
  description = <<DESCRIPTION
This variable controls whether or not telemetry is enabled for the module.
For more information see https://aka.ms/avm/telemetryinfo.
If it is set to false, then no telemetry will be collected.
DESCRIPTION
}

# This is required for most resource modules
variable "resource_group_name" {
  type        = string
  description = "The resource group where the resources will be deployed."
}


variable "name" {
  type        = string
  description = "Name of public IP address resource"
  validation {
    condition     = can(regex("^[a-zA-Z0-9]([a-zA-Z0-9._-]{0,78}[a-zA-Z0-9_])?$", var.name))
    error_message = "The name must be between 3 and 24 characters long and can only contain lowercase letters, numbers and dashes."
  }
}

variable "location" {
  type        = string
  description = "The Azure location where the resources will be deployed."
}

variable "zones" {
  type        = set(number)
  description = "A set of availability zones to use."
  default     = [1, 2, 3]
}

variable "sku" {
  type        = string
  description = "The SKU of the public IP address."
  default     = "Standard"
  validation {
    condition     = can(regex("^(Basic|Standard)$", var.sku))
    error_message = "The SKU must be either 'Basic' or 'Standard'."
  }

}

variable "sku_tier" {
  type        = string
  description = "The tier of the SKU of the public IP address."
  default     = "Regional" #check this with Seif
  validation {
    condition     = can(regex("^(Global|Regional)$", var.sku_tier))
    error_message = "The SKU tier must be either 'Global' or 'Regional'."
  }
}

variable "ip_version" {
  type        = string
  description = "The IP version to use."
  default     = "IPv4"
  validation {
    condition     = can(regex("^(IPv4|IPv6)$", var.ip_version))
    error_message = "The IP version must be either 'IPv4' or 'IPv6'."
  }
}

variable "allocation_method" {
  type        = string
  description = "The allocation method to use."
  default     = "Static"
  validation {
    condition     = can(regex("^(Static|Dynamic)$", var.allocation_method))
    error_message = "The allocation method must be either 'Static' or 'Dynamic'."
  }
}

variable "domain_name_label" {
  type        = string
  description = "The domain name label for the public IP address."
  default     = null
}

variable "reverse_fqdn" {
  type        = string
  description = "The reverse FQDN for the public IP address. This must be a valid FQDN. If you specify a reverse FQDN, you cannot specify a DNS name label. Not all regions support this."
  default     = null
}

variable "public_ip_prefix_id" {
  type        = string
  description = "The ID of the public IP prefix to associate with the public IP address."
  default     = null
}

variable "idle_timeout_in_minutes" {
  type        = number
  description = "The idle timeout in minutes."
  default     = 4
  validation {
    condition     = can(regex("^[0-9]{1,4}$", var.idle_timeout_in_minutes))
    error_message = "The idle timeout must be between 1 and 4 digits long."
  }

}
variable "ip_tags" {
  type        = map(string)
  description = "The IP tags for the public IP address"
  default     = {}
}
variable "ddos_protection_mode" {
  type        = string
  description = "The DDoS protection mode to use."
  default     = "VirtualNetworkInherited"
  validation {
    condition     = can(regex("^(Disabled|Enabled|VirtualNetworkInherited)$", var.ddos_protection_mode))
    error_message = "The DDoS protection mode must be either 'Basic' or 'Standard'."
  }

}

variable "ddos_protection_plan_id" {
  type        = string
  description = "The ID of the DDoS protection plan to associate with the public IP address. This is required if `ddos_protection_mode` is set to `Standard`."
  default     = null
}

variable "edge_zone" {
  type        = string
  description = "The edge zone to use for the public IP address. This is required if `sku_tier` is set to `Global`."
  default     = null
}

variable "tags" {
  type        = map(any)
  description = "Map of tags to assign to the deployed resource."
  default     = null
}

variable "lock" {
  type = object({
    name = optional(string, null)
    kind = optional(string, "None")
  })
  description = "The lock level to apply to the deployed resource. Default is `None`. Possible values are `None`, `CanNotDelete`, and `ReadOnly`."
  default     = {}
  nullable    = false
  validation {
    condition     = contains(["CanNotDelete", "ReadOnly", "None"], var.lock.kind)
    error_message = "The lock level must be one of: 'None', 'CanNotDelete', or 'ReadOnly'."
  }
}

variable "role_assignments" {
  type = map(object({
    role_definition_id_or_name             = string
    principal_id                           = string
    description                            = optional(string, null)
    skip_service_principal_aad_check       = optional(bool, false)
    condition                              = optional(string, null)
    condition_version                      = optional(string, null)
    delegated_managed_identity_resource_id = optional(string, null)
  }))
  default     = {}
  description = <<DESCRIPTION
 A map of role assignments to create on this resource. The map key is deliberately arbitrary to avoid issues where map keys maybe unknown at plan time.

- `role_definition_id_or_name` - The ID or name of the role definition to assign to the principal.
- `principal_id` - The ID of the principal to assign the role to.
- `description` - The description of the role assignment.
- `skip_service_principal_aad_check` - If set to true, skips the Azure Active Directory check for the service principal in the tenant. Defaults to false.
- `condition` - The condition which will be used to scope the role assignment.
- `condition_version` - The version of the condition syntax. Valid values are '2.0'.

> Note: only set `skip_service_principal_aad_check` to true if you are assigning a role to a service principal.
DESCRIPTION
}

variable "diagnostic_settings" {
  type = map(object({
    name                                     = optional(string, null)
    log_categories                           = optional(set(string), [])
    log_groups                               = optional(set(string), ["allLogs"])
    metric_categories                        = optional(set(string), ["AllMetrics"])
    log_analytics_destination_type           = optional(string, "Dedicated")
    workspace_resource_id                    = optional(string, null)
    storage_account_resource_id              = optional(string, null)
    event_hub_authorization_rule_resource_id = optional(string, null)
    event_hub_name                           = optional(string, null)
    marketplace_partner_resource_id          = optional(string, null)
  }))
  default  = {}
  nullable = false

  validation {
    condition     = alltrue([for _, v in var.diagnostic_settings : contains(["Dedicated", "AzureDiagnostics"], v.log_analytics_destination_type)])
    error_message = "Log analytics destination type must be one of: 'Dedicated', 'AzureDiagnostics'."
  }
  validation {
    condition = alltrue(
      [
        for _, v in var.diagnostic_settings :
        v.workspace_resource_id != null || v.storage_account_resource_id != null || v.event_hub_authorization_rule_resource_id != null || v.marketplace_partner_resource_id != null
      ]
    )
    error_message = "At least one of `workspace_resource_id`, `storage_account_resource_id`, `marketplace_partner_resource_id`, or `event_hub_authorization_rule_resource_id`, must be set."
  }
  description = <<DESCRIPTION
A map of diagnostic settings to create on the ddos protection plan. The map key is deliberately arbitrary to avoid issues where map keys maybe unknown at plan time.

- `name` - (Optional) The name of the diagnostic setting. One will be generated if not set, however this will not be unique if you want to create multiple diagnostic setting resources.
- `log_categories` - (Optional) A set of log categories to send to the log analytics workspace. Defaults to `[]`.
- `log_groups` - (Optional) A set of log groups to send to the log analytics workspace. Defaults to `["allLogs"]`.
- `metric_categories` - (Optional) A set of metric categories to send to the log analytics workspace. Defaults to `["AllMetrics"]`.
- `log_analytics_destination_type` - (Optional) The destination type for the diagnostic setting. Possible values are `Dedicated` and `AzureDiagnostics`. Defaults to `Dedicated`.
- `workspace_resource_id` - (Optional) The resource ID of the log analytics workspace to send logs and metrics to.
- `storage_account_resource_id` - (Optional) The resource ID of the storage account to send logs and metrics to.
- `event_hub_authorization_rule_resource_id` - (Optional) The resource ID of the event hub authorization rule to send logs and metrics to.
- `event_hub_name` - (Optional) The name of the event hub. If none is specified, the default event hub will be selected.
- `marketplace_partner_resource_id` - (Optional) The full ARM resource ID of the Marketplace resource to which you would like to send Diagnostic LogsLogs.
DESCRIPTION
}
