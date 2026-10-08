# ---------------------------------------------------------------------------
# Request bodies, parent scope, per-resource timeout fallbacks, and the
# state-vs-config comparisons that back the ForceNew preconditions in
# `main.tf`.
#
# Every body below is built with `merge()` rather than with `attr = null`, so
# an optional the consumer left unset is ABSENT from the object rather than
# present-and-null. That matters twice:
#   - on the create-only writer it reproduces AzureRM's `omitempty`
#     serialisation exactly (`ignore_null_property = true` would also do it,
#     and is kept as belt and braces);
#   - on the MERGE writer it is the only thing that works. That resource has no
#     `ignore_null_property` attribute in azapi 2.13.0, so a present-and-null
#     key would be merged into the live object as an explicit null.
# ---------------------------------------------------------------------------
locals {
  # The ARM parent scope. Supplied whole by the caller -- the module never
  # constructs it (TFRMFR1, `avm-tf-azapi` SKILL L167-182).
  parent_id = var.parent_id
  # Subscription scope, used only to let `avm-utl-interfaces` resolve a role
  # definition NAME to its resource ID (the lookup AzureRM performed itself).
  parent_subscription_id = "/subscriptions/${split("/", local.parent_id)[2]}"
}

locals {
  # PIP L239-L266. AzureRM always sent `ddosSettings.protectionMode`, and
  # attached `ddosProtectionPlan` only when the plan ID was set.
  public_ip_ddos_settings = merge(
    {
      protectionMode = var.ddos_protection_mode
    },
    var.ddos_protection_plan_id != null ? {
      ddosProtectionPlan = { id = var.ddos_protection_plan_id }
    } : {},
  )
  # PIP L283-L300. AzureRM built `dnsSettings` only when at least one of
  # `domain_name_label` / `reverse_fqdn` was set, and omitted the object
  # entirely otherwise. `domain_name_label_scope` is not exposed by this
  # module, so it is not in either half.
  public_ip_dns_settings = length(local.public_ip_dns_settings_members) > 0 ? local.public_ip_dns_settings_members : null
  public_ip_dns_settings_members = merge(
    var.domain_name_label != null ? { domainNameLabel = var.domain_name_label } : {},
    var.reverse_fqdn != null ? { reverseFqdn = var.reverse_fqdn } : {},
  )
  # PIP L302-L315. A map of tag-type -> tag becomes an ARM array of objects.
  public_ip_ip_tags = [for ip_tag_type, ip_tag in var.ip_tags : {
    ipTagType = ip_tag_type
    tag       = ip_tag
  }]
  # ARM types `zones` as an array of STRINGS; the module's public API is
  # `set(number)`, which AzureRM converted internally.
  public_ip_zones = [for zone in var.zones : tostring(zone)]
}

locals {
  # GENESIS BODY -- what AzureRM's CREATE sent, member for member
  # (`public_ip_resource.go` L241-L315 at azurerm v4.x).
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

  # DAY-2 MERGE BODY -- the NON-ForceNew subset only.
  #
  # AzureRM's `resourcePublicIpUpdate` (PIP L340-L410) is `payload :=
  # existing.Model` followed by guarded assignments, i.e. GET-then-patch-then-
  # PUT. The four members it could assign were `publicIPAllocationMethod`,
  # `ddosSettings.protectionMode`, `idleTimeoutInMinutes` and `dnsSettings`.
  # (`ddosSettings.ddosProtectionPlan` also has an assignment there, but the
  # schema marks `ddos_protection_plan_id` ForceNew at PIP L95, so that branch
  # is unreachable -- the diff replaces first. It is therefore a PRECONDITION
  # here, not a merge member.)
  #
  # `tags` is NOT here. A merge writer cannot REMOVE a key, so tags go through
  # `azapi_resource_action.tags`, which PUTs the whole set.
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
  # FORCENEW COMPARISONS. Each pair is built by the SAME expression on both
  # sides -- one reading `azapi_resource.this.body` (the STATE body, pinned by
  # `ignore_changes = [body]` on the create-only writer) and one reading the
  # genesis body -- so an absent member yields `null`/`[]` on both sides and a
  # non-zonal, non-edge-zone, prefix-less public IP passes every check.
  #
  # The list is exhaustive against every `ForceNew: true` in
  # `public_ip_resource.go` at azurerm v4.x:
  #   L60  name                     -> azapi `name`        (native RequiresReplace)
  #   L95  ddos_protection_plan_id  -> properties.ddosSettings.ddosProtectionPlan.id
  #   L101 ip_version               -> properties.publicIPAddressVersion
  #   L111 sku                      -> sku.name
  #   L121 sku_tier                 -> sku.tier
  #   L165 public_ip_prefix_id      -> properties.publicIPPrefix.id
  #   L172 ip_tags                  -> properties.ipTags
  #   L95  edge_zone (commonschema.EdgeZoneOptionalForceNew)      -> extendedLocation.name
  #   L178 zones     (commonschema.ZonesMultipleOptionalForceNew) -> zones
  #   plus `location` and `resource_group_name`, which are azapi `location` and
  #   `parent_id` and already force replacement natively.
  # `domain_name_label_scope` (ForceNewIfChange, L200) is not exposed.
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
  # Was `dnsSettings` present before and is it gone now? A merge writer cannot
  # un-set it, so removal has to be refused rather than silently dropped.
  pip_state_had_dns_settings = try(azapi_resource.this.body.properties.dnsSettings, null) != null
}

locals {
  # Diagnostic-setting bodies. The shape comes from `avm-utl-interfaces`, with
  # ONE override: AzureRM sent NOTHING for `log_analytics_destination_type ==
  # "Dedicated"` (main.tf L53 of the AzureRM implementation), while the
  # interfaces module always sends the literal. Preserving AzureRM's behaviour
  # keeps the upgrade plan free of a body diff on every existing diagnostic
  # setting.
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
  # AzureRM always set a lock note; `avm-utl-interfaces` leaves `notes` null.
  # Variant-2 of the AVM lock interface exposes `notes`, so a consumer value
  # wins and the AzureRM string is the fallback.
  lock_notes = var.lock == null ? null : (
    var.lock.notes != null ? var.lock.notes : (
      var.lock.kind == "CanNotDelete" ? "Cannot delete the resource or its child resources." : "Cannot delete or modify the resource or its child resources."
    )
  )
  # `tags.Expand(nil)` in AzureRM returns a pointer to an EMPTY map, never nil,
  # so an untagged public IP was PUT with `"tags": {}`. Used by the tag writer
  # only -- `azapi_resource.this` must set `tags = var.tags` literally
  # (`avm_azapi_resource_tags_required`).
  public_ip_tags = var.tags == null ? {} : var.tags
}

locals {
  # 🔴 TFFR7 / `avm_interface_timeouts`: `timeouts` must PERMIT `null`, so the
  # input cannot be fenced off with `nullable = false` and is normalised here
  # instead. A null input is identical to every member being null -- the
  # AzureRM defaults below apply.
  timeouts_requested = var.timeouts == null ? {
    create = null
    delete = null
    read   = null
    update = null
  } : var.timeouts
}

locals {
  # PER-RESOURCE TIMEOUT FALLBACKS. `var.timeouts` is a single flat object, so
  # a consumer override applies everywhere; when a member is null the module
  # falls back to the AzureRM default FOR THAT RESOURCE TYPE, which keeps the
  # migration timeout-neutral.
  #
  #   publicIPAddresses    create 30m / read 5m / update 30m / delete 30m
  #                        (`public_ip_resource.go` L50-L53)
  #   locks                create 30m / read 5m / update 30m / delete 30m
  #                        (`management_lock_resource.go`)
  #   roleAssignments      create 30m / read 5m / update 30m / delete 30m
  #                        (`role_assignment_resource.go`)
  #   diagnosticSettings   create 30m / read 5m / update 30m / delete 60m
  #                        (`monitor_diagnostic_setting_resource.go`)
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
