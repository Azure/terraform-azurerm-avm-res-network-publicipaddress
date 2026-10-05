variable "location" {
  type        = string
  description = "The Azure location where the resources will be deployed."
  nullable    = false
}

variable "name" {
  type        = string
  description = "Name of public IP address resource"

  validation {
    condition     = can(regex("^[a-zA-Z0-9]([a-zA-Z0-9._-]{0,78}[a-zA-Z0-9_])?$", var.name))
    error_message = "The name must be between 3 and 24 characters long and can only contain lowercase letters, numbers and dashes."
  }
}

variable "parent_id" {
  type        = string
  description = <<DESCRIPTION
The fully-qualified ARM resource ID of the existing resource group into which the public IP address will be deployed, for example `/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example`.

This input is REQUIRED. Per TFRMFR1 a resource module accepts the existing parent scope as a fully-qualified ID and never constructs it; the module does not accept a `resource_group_name` alternative and does not create the parent scope.
DESCRIPTION

  # TFNFR38.
  validation {
    condition     = can(provider::azapi::parse_resource_id("Microsoft.Resources/resourceGroups", var.parent_id))
    error_message = "`parent_id` must be a valid resource group resource ID."
  }
}

variable "allocation_method" {
  type        = string
  default     = "Static"
  description = "The allocation method to use."

  validation {
    condition     = can(regex("^(Static|Dynamic)$", var.allocation_method))
    error_message = "The allocation method must be either 'Static' or 'Dynamic'."
  }
}

variable "ddos_protection_mode" {
  type        = string
  default     = "VirtualNetworkInherited"
  description = "The DDoS protection mode to use."

  validation {
    condition     = can(regex("^(Disabled|Enabled|VirtualNetworkInherited)$", var.ddos_protection_mode))
    error_message = "The DDoS protection mode must be either 'Basic' or 'Standard'."
  }
}

variable "ddos_protection_plan_id" {
  type        = string
  default     = null
  description = "The ID of the DDoS protection plan to associate with the public IP address. This is required if `ddos_protection_mode` is set to `Standard`."

  # TFNFR38. AzureRM validated this with `azure.ValidateResourceID`
  # (public_ip_resource.go L93); the AzAPI equivalent is the provider-defined
  # parser. `null` is the documented default and must stay acceptable.
  validation {
    condition     = var.ddos_protection_plan_id == null ? true : can(provider::azapi::parse_resource_id("Microsoft.Network/ddosProtectionPlans", var.ddos_protection_plan_id))
    error_message = "`ddos_protection_plan_id` must be a valid `Microsoft.Network/ddosProtectionPlans` resource ID."
  }
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
  default     = {}
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
  nullable    = false

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
}

variable "domain_name_label" {
  type        = string
  default     = null
  description = "The domain name label for the public IP address."
}

variable "edge_zone" {
  type        = string
  default     = null
  description = "The edge zone to use for the public IP address. This is required if `sku_tier` is set to `Global`."
}

variable "enable_telemetry" {
  type        = bool
  default     = true
  description = <<DESCRIPTION
This variable controls whether or not telemetry is enabled for the module.
For more information see <https://aka.ms/avm/telemetryinfo>.
If it is set to false, then no telemetry will be collected.
DESCRIPTION
  nullable    = false
}

variable "idle_timeout_in_minutes" {
  type        = number
  default     = 4
  description = "The idle timeout in minutes."

  validation {
    condition     = can(regex("^[0-9]{1,4}$", var.idle_timeout_in_minutes))
    error_message = "The idle timeout must be between 1 and 4 digits long."
  }
}

variable "ignore_body_changes" {
  type = object({
    network_public_ip_addresses    = optional(list(string), [])
    authorization_locks            = optional(list(string), [])
    authorization_role_assignments = optional(list(string), [])
    insights_diagnostic_settings   = optional(list(string), [])
  })
  default     = {}
  description = <<DESCRIPTION
Body-relative paths to ignore for each AzAPI resource. Paths use dot notation.
Changes take effect only after apply. Ignored configuration is not sent to Azure
until the path is removed.

- `network_public_ip_addresses` - Paths ignored on the public IP address resource.
- `authorization_locks` - Paths ignored on the management lock resource.
- `authorization_role_assignments` - Paths ignored on the role assignment resources.
- `insights_diagnostic_settings` - Paths ignored on the diagnostic setting resources.

> NOTE: non-empty values require Terraform 1.11 or later. The module collapses
> an empty list to `null`, so the write-only argument stays absent at the
> default and consumers on Terraform 1.9/1.10 are unaffected.

> NOTE: `network_public_ip_addresses` reaches the CREATE-ONLY writer only. That
> writer already ignores every body change after create (see `main.tf`), so the
> field has almost no reach. The day-2 merge writer is an
> `azapi_update_resource`, and azapi 2.13.0 does not implement
> `ignore_body_changes` on that resource type at all.
DESCRIPTION
  nullable    = false

  validation {
    condition = alltrue([
      for paths in values(var.ignore_body_changes) : alltrue([for p in paths : length(trimspace(p)) > 0])
    ])
    error_message = "Every `ignore_body_changes` path must be a non-empty, body-relative dot path (for example `properties.sku.name`)."
  }
}

variable "ip_tags" {
  type        = map(string)
  default     = {}
  description = "The IP tags for the public IP address"
}

variable "ip_version" {
  type        = string
  default     = "IPv4"
  description = "The IP version to use."

  validation {
    condition     = can(regex("^(IPv4|IPv6)$", var.ip_version))
    error_message = "The IP version must be either 'IPv4' or 'IPv6'."
  }
}

variable "lock" {
  type = object({
    kind  = string
    name  = optional(string, null)
    notes = optional(string, null)
  })
  default     = null
  description = <<DESCRIPTION
Controls the Resource Lock configuration for this resource. The following properties can be specified:

- `kind` - (Required) The type of lock. Possible values are `\"CanNotDelete\"` and `\"ReadOnly\"`.
- `name` - (Optional) The name of the lock. If not specified, a name will be generated based on the `kind` value. Changing this forces the creation of a new resource.
- `notes` - (Optional) A note about the lock. If not specified, the module supplies the same note the AzureRM implementation used for the chosen `kind`.
DESCRIPTION

  validation {
    condition     = var.lock != null ? contains(["CanNotDelete", "ReadOnly"], var.lock.kind) : true
    error_message = "Lock kind must be either `\"CanNotDelete\"` or `\"ReadOnly\"`."
  }
}

variable "public_ip_prefix_id" {
  type        = string
  default     = null
  description = "The ID of the public IP prefix to associate with the public IP address."

  # TFNFR38. AzureRM validated this with `azure.ValidateResourceID`
  # (public_ip_resource.go L166).
  validation {
    condition     = var.public_ip_prefix_id == null ? true : can(provider::azapi::parse_resource_id("Microsoft.Network/publicIPPrefixes", var.public_ip_prefix_id))
    error_message = "`public_ip_prefix_id` must be a valid `Microsoft.Network/publicIPPrefixes` resource ID."
  }
}

variable "resource_types" {
  type = object({
    network_public_ip_addresses    = optional(string, "Microsoft.Network/publicIPAddresses@2025-07-01")
    authorization_locks            = optional(string, "Microsoft.Authorization/locks@2020-05-01")
    authorization_role_assignments = optional(string, "Microsoft.Authorization/roleAssignments@2022-04-01")
    insights_diagnostic_settings   = optional(string, "Microsoft.Insights/diagnosticSettings@2021-05-01-preview")
    resources_tags                 = optional(string, "Microsoft.Resources/tags@2021-04-01")
  })
  default     = {}
  description = <<DESCRIPTION
AzAPI resource types and API versions used by the module.

- `network_public_ip_addresses` - Resource type and API version for the public IP address.
- `authorization_locks` - Resource type and API version for the management lock.
- `authorization_role_assignments` - Resource type and API version for role assignments.
- `insights_diagnostic_settings` - Resource type and API version for diagnostic settings.
- `resources_tags` - Resource type and API version for the tag replacement action.

> NOTE: the defaults are deliberately the NEWEST versions embedded in the AzAPI
> provider that this module resolves (2.13.0). `azapi`'s `MoveResourceState`
> picks `candidateApiVersions[len-1]` after a lexicographic sort, so pinning the
> newest version makes the `moved` upgrade plan show ZERO `type` drift. Changing
> a default away from the newest embedded version reintroduces that drift on the
> upgrade plan.
DESCRIPTION
  nullable    = false
}

variable "retry" {
  type = object({
    error_message_regex  = optional(list(string), ["ReferencedResourceNotProvisioned", "AnotherOperationInProgress"])
    interval_seconds     = optional(number, null)
    max_interval_seconds = optional(number, null)
  })
  default     = {}
  description = <<DESCRIPTION
The retry configuration applied to the underlying `azapi_resource` resources (public IP address, lock, role assignments, diagnostic settings, tags).

- `error_message_regex` - (Optional) A list of regular expressions to match against error messages. If any of the regular expressions match, the request will be retried. Defaults to the two transient ARM errors a public IP address attracts while it is being attached to or detached from a load balancer, NAT gateway or NIC.
- `interval_seconds` - (Optional) The base number of seconds to wait between retries. Defaults to the AzAPI provider default (`10`).
- `max_interval_seconds` - (Optional) The maximum number of seconds to wait between retries. Defaults to the AzAPI provider default (`180`).
DESCRIPTION
}

variable "reverse_fqdn" {
  type        = string
  default     = null
  description = "The reverse FQDN for the public IP address. This must be a valid FQDN. If you specify a reverse FQDN, you cannot specify a DNS name label. Not all regions support this."
}

variable "role_assignments" {
  type = map(object({
    name                                   = optional(string, null)
    role_definition_id_or_name             = string
    principal_id                           = string
    description                            = optional(string, null)
    skip_service_principal_aad_check       = optional(bool, false)
    condition                              = optional(string, null)
    condition_version                      = optional(string, null)
    delegated_managed_identity_resource_id = optional(string, null)
    principal_type                         = optional(string, null)
  }))
  default     = {}
  description = <<DESCRIPTION
A map of role assignments to create on the <RESOURCE>. The map key is deliberately arbitrary to avoid issues where map keys maybe unknown at plan time.

- `name` - (Optional) The name (a lowercase GUID) of the role assignment. If not set, a random UUID is generated. Existing role assignments migrated from the AzureRM implementation keep their server-assigned name; see the `lifecycle` note in `main.tf`.
- `role_definition_id_or_name` - The ID or name of the role definition to assign to the principal.
- `principal_id` - The ID of the principal to assign the role to.
- `description` - (Optional) The description of the role assignment.
- `skip_service_principal_aad_check` - (Optional) DEPRECATED -- has no effect under AzAPI. ARM has no equivalent request property; AzureRM implemented it as a client-side retry loop.
- `condition` - (Optional) The condition which will be used to scope the role assignment.
- `condition_version` - (Optional) The version of the condition syntax. Leave as `null` if you are not using a condition, if you are then valid values are '2.0'.
- `delegated_managed_identity_resource_id` - (Optional) The delegated Azure Resource Id which contains a Managed Identity. Changing this forces a new resource to be created. This field is only used in cross-tenant scenario.
- `principal_type` - (Optional) The type of the `principal_id`. Possible values are `User`, `Group` and `ServicePrincipal`. It is necessary to explicitly set this attribute when creating role assignments if the principal creating the assignment is constrained by ABAC rules that filters on the PrincipalType attribute.

> Note: only set `skip_service_principal_aad_check` to true if you are assigning a role to a service principal.
DESCRIPTION
  nullable    = false

  validation {
    error_message = "Each role_assignments `name`, when supplied, must be a valid lowercase GUID (e.g. 11111111-1111-1111-1111-111111111111)."
    condition = alltrue([
      for ra in var.role_assignments :
      ra.name == null || can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", ra.name))
    ])
  }
}

variable "sku" {
  type        = string
  default     = "Standard"
  description = "The SKU of the public IP address."

  validation {
    condition     = can(regex("^(Basic|Standard)$", var.sku))
    error_message = "The SKU must be either 'Basic' or 'Standard'."
  }
}

variable "sku_tier" {
  type        = string
  default     = "Regional" #check this with Seif
  description = "The tier of the SKU of the public IP address."

  validation {
    condition     = can(regex("^(Global|Regional)$", var.sku_tier))
    error_message = "The SKU tier must be either 'Global' or 'Regional'."
  }
}

variable "tags" {
  type        = map(string)
  default     = null
  description = "(Optional) Tags of the resource."
}

variable "timeouts" {
  type = object({
    create = optional(string, null)
    delete = optional(string, null)
    read   = optional(string, null)
    update = optional(string, null)
  })
  default     = {}
  description = <<DESCRIPTION
The timeouts applied to the underlying `azapi_resource` resources (public IP address, lock, role assignments, diagnostic settings).

Each value must be a string parsable as a Go duration (for example `"30s"`, `"5m"`, `"1h30m"`). When `null`, this module falls back to the per-resource default that the AzureRM implementation used, so the migration is timeout-neutral. Supplying `null` for the whole object is equivalent to supplying every member as `null`.

- `create` - (Optional) Timeout for create operations.
- `delete` - (Optional) Timeout for delete operations.
- `read` - (Optional) Timeout for read operations.
- `update` - (Optional) Timeout for update operations.
DESCRIPTION
}

variable "zones" {
  type        = set(number)
  default     = [1, 2, 3]
  description = "A set of availability zones to use."
}
