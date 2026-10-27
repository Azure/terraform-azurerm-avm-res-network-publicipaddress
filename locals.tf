# ---------------------------------------------------------------------------
# Request bodies, parent scope, per-resource timeout fallbacks, and the
# state-vs-config comparisons behind the ForceNew preconditions in `main.tf`.
#
# Every body is built with `merge()` rather than `attr = null`, so an unset
# optional is absent from the object instead of present-and-null. The create
# writer would tolerate nulls (`ignore_null_property`), but the merge writer has
# no such attribute in azapi 2.13.0, so a null key would be merged into the live
# object as an explicit null.
# ---------------------------------------------------------------------------
locals {
  # The ARM parent scope, supplied whole by the caller (TFRMFR1).
  parent_id = var.parent_id
}

locals {
  # AzureRM always sent `ddosSettings.protectionMode`, and attached
  # `ddosProtectionPlan` only when the plan ID was set.
  public_ip_ddos_settings = merge(
    {
      protectionMode = var.ddos_protection_mode
    },
    var.ddos_protection_plan_id != null ? {
      ddosProtectionPlan = { id = var.ddos_protection_plan_id }
    } : {},
  )
  # AzureRM built `dnsSettings` only when `domain_name_label` or `reverse_fqdn`
  # was set. `domain_name_label_scope` is not exposed by this module.
  public_ip_dns_settings = length(local.public_ip_dns_settings_members) > 0 ? local.public_ip_dns_settings_members : null
  public_ip_dns_settings_members = merge(
    var.domain_name_label != null ? { domainNameLabel = var.domain_name_label } : {},
    var.reverse_fqdn != null ? { reverseFqdn = var.reverse_fqdn } : {},
  )
  # A map of tag-type -> tag becomes an ARM array of objects.
  public_ip_ip_tags = [for ip_tag_type, ip_tag in var.ip_tags : {
    ipTagType = ip_tag_type
    tag       = ip_tag
  }]
  # ARM types `zones` as strings; the module's input is `set(number)`.
  public_ip_zones = [for zone in var.zones : tostring(zone)]
}

locals {
  # Genesis body: what AzureRM's create sent, member for member.
  public_ip_body = merge(
    {
      sku = {
        name = var.sku
        tier = var.sku_tier
      }
      properties = merge(
        {
          publicIPAllocationMethod = var.allocation_method
          publicIPAddressVersion   = var.ip_version
          idleTimeoutInMinutes     = var.idle_timeout_in_minutes
          ddosSettings             = local.public_ip_ddos_settings
        },
        local.public_ip_dns_settings != null ? { dnsSettings = local.public_ip_dns_settings } : {},
        var.public_ip_prefix_id != null ? { publicIPPrefix = { id = var.public_ip_prefix_id } } : {},
        length(var.ip_tags) > 0 ? { ipTags = local.public_ip_ip_tags } : {},
      )
    },
    var.edge_zone != null ? {
      extendedLocation = {
        name = var.edge_zone
        type = "EdgeZone"
      }
    } : {},
    length(var.zones) > 0 ? { zones = local.public_ip_zones } : {},
  )

  # Day-2 merge body: the non-ForceNew subset only. AzureRM's update path was
  # GET, patch, PUT, and could assign `publicIPAllocationMethod`,
  # `ddosSettings.protectionMode`, `idleTimeoutInMinutes` and `dnsSettings`.
  # `ddosProtectionPlan` is a precondition instead, because the schema marks it
  # ForceNew. `tags` is not here: a merge writer cannot remove a key, so tags go
  # through `azapi_resource_action.tags`.
  public_ip_update_body = {
    properties = merge(
      {
        publicIPAllocationMethod = var.allocation_method
        idleTimeoutInMinutes     = var.idle_timeout_in_minutes
        ddosSettings             = { protectionMode = var.ddos_protection_mode }
      },
      local.public_ip_dns_settings != null ? { dnsSettings = local.public_ip_dns_settings } : {},
    )
  }
}

locals {
  # ===========================================================================
  # ForceNew comparisons. Each pair is built by the same expression on both
  # sides, one reading `azapi_resource.this.body` (the state body) and one the
  # genesis body, so an absent member is `null`/`[]` on both sides.
  #
  # Covered: ddos_protection_plan_id, ip_version, sku, sku_tier,
  # public_ip_prefix_id, ip_tags, edge_zone and zones. `name`, `location` and
  # `parent_id` already force replacement natively in azapi, and
  # `domain_name_label_scope` is not exposed.
  # ===========================================================================
  pip_config_ddos_plan_id = try(lower(tostring(local.public_ip_body.properties.ddosSettings.ddosProtectionPlan.id)), null)
  pip_config_edge_zone    = try(lower(tostring(local.public_ip_body.extendedLocation.name)), null)
  pip_config_ip_tags      = toset(try([for ip_tag in local.public_ip_body.properties.ipTags : "${ip_tag.ipTagType}=${ip_tag.tag}"], []))
  pip_config_ip_version   = try(lower(tostring(local.public_ip_body.properties.publicIPAddressVersion)), null)
  pip_config_prefix_id    = try(lower(tostring(local.public_ip_body.properties.publicIPPrefix.id)), null)
  pip_config_sku_name     = try(lower(tostring(local.public_ip_body.sku.name)), null)
  pip_config_sku_tier     = try(lower(tostring(local.public_ip_body.sku.tier)), null)
  pip_config_zones        = toset(try([for zone in local.public_ip_body.zones : tostring(zone)], []))
  pip_config_dns_label    = try(tostring(local.public_ip_body.properties.dnsSettings.domainNameLabel), null)
  pip_config_reverse_fqdn = try(tostring(local.public_ip_body.properties.dnsSettings.reverseFqdn), null)
  pip_state_ddos_plan_id  = try(lower(tostring(azapi_resource.this.body.properties.ddosSettings.ddosProtectionPlan.id)), null)
  pip_state_edge_zone     = try(lower(tostring(azapi_resource.this.body.extendedLocation.name)), null)
  pip_state_ip_tags       = toset(try([for ip_tag in azapi_resource.this.body.properties.ipTags : "${ip_tag.ipTagType}=${ip_tag.tag}"], []))
  pip_state_ip_version    = try(lower(tostring(azapi_resource.this.body.properties.publicIPAddressVersion)), null)
  pip_state_prefix_id     = try(lower(tostring(azapi_resource.this.body.properties.publicIPPrefix.id)), null)
  pip_state_sku_name      = try(lower(tostring(azapi_resource.this.body.sku.name)), null)
  pip_state_sku_tier      = try(lower(tostring(azapi_resource.this.body.sku.tier)), null)
  pip_state_zones         = toset(try([for zone in azapi_resource.this.body.zones : tostring(zone)], []))
  pip_state_dns_label     = try(tostring(azapi_resource.this.body.properties.dnsSettings.domainNameLabel), null)
  pip_state_reverse_fqdn  = try(tostring(azapi_resource.this.body.properties.dnsSettings.reverseFqdn), null)
}

locals {
  # Diagnostic-setting bodies, shaped by `avm-utl-interfaces` with one override:
  # AzureRM sent nothing for `log_analytics_destination_type == "Dedicated"`,
  # while the interfaces module always sends the literal. Matching AzureRM keeps
  # the upgrade plan free of a body diff on existing diagnostic settings.
  diagnostic_setting_bodies = {
    for key, setting in module.interfaces.diagnostic_settings_azapi : key => {
      properties = merge(
        setting.body.properties,
        {
          logAnalyticsDestinationType = var.diagnostic_settings[key].log_analytics_destination_type == "Dedicated" ? null : var.diagnostic_settings[key].log_analytics_destination_type
        },
      )
    }
  }
  # AzureRM generated `diag-<pip name>` when the consumer left `name` unset.
  diagnostic_setting_names = {
    for key, setting in var.diagnostic_settings : key => setting.name != null ? setting.name : "diag-${var.name}"
  }
}

locals {
  # AzureRM always set a lock note and `avm-utl-interfaces` leaves it null. A
  # consumer value wins; the AzureRM string is the fallback.
  lock_notes = var.lock == null ? null : (
    var.lock.notes != null ? var.lock.notes : (
      var.lock.kind == "CanNotDelete" ? "Cannot delete the resource or its child resources." : "Cannot delete or modify the resource or its child resources."
    )
  )
  # AzureRM PUT `"tags": {}` for an untagged public IP. Used by the tag writer
  # only; `azapi_resource.this` must set `tags = var.tags` literally
  # (`avm_azapi_resource_tags_required`).
  public_ip_tags = var.tags == null ? {} : var.tags
}

locals {
  # TFFR7 / `avm_interface_timeouts`: `timeouts` must permit `null`, so it is
  # normalised here instead of fenced off with `nullable = false`. A null input
  # means every member is null and the AzureRM defaults below apply.
  timeouts_requested = var.timeouts == null ? {
    create = null
    delete = null
    read   = null
    update = null
  } : var.timeouts
}

locals {
  # Per-resource timeout fallbacks. `var.timeouts` is one flat object, so an
  # override applies everywhere. A null member falls back to the AzureRM default
  # for that resource type (create/read/update/delete: 30m/5m/30m/30m, except
  # diagnostic settings, which delete in 60m), keeping the migration
  # timeout-neutral.
  timeouts = {
    for resource_key, defaults in {
      network_public_ip_addresses    = { create = "30m", read = "5m", update = "30m", delete = "30m" }
      authorization_locks            = { create = "30m", read = "5m", update = "30m", delete = "30m" }
      authorization_role_assignments = { create = "30m", read = "5m", update = "30m", delete = "30m" }
      insights_diagnostic_settings   = { create = "30m", read = "5m", update = "30m", delete = "60m" }
      } : resource_key => {
      create = local.timeouts_requested.create != null ? local.timeouts_requested.create : defaults.create
      delete = local.timeouts_requested.delete != null ? local.timeouts_requested.delete : defaults.delete
      read   = local.timeouts_requested.read != null ? local.timeouts_requested.read : defaults.read
      update = local.timeouts_requested.update != null ? local.timeouts_requested.update : defaults.update
    }
  }
}
