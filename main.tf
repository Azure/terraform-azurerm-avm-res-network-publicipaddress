# ---------------------------------------------------------------------------
# Public IP address, migrated in place from `hashicorp/azurerm` to `Azure/azapi`
# (`avm-tf-migration` SKILL): same module, same keys, only the provider and the
# request bodies moved.
#
# `azapi_resource.this` creates the public IP once and never PUTs again. Every
# later write goes through `azapi_update_resource.this`, which GETs the live
# object and merges. A full PUT could drop writable members this module does
# not declare (`properties.ipAddress`, `natGateway`, `linkedPublicIPAddress`,
# `servicePublicIPAddress`, `deleteOption`, `dnsSettings.domainNameLabelScope`).
# AzureRM avoided that the same way, by updating the existing object.
# ---------------------------------------------------------------------------

# Standard AVM interfaces (lock, role assignments, diagnostic settings).
module "interfaces" {
  source = "Azure/avm-utl-interfaces/azure"
  # Exact pin: the AVM lint requires one, and `~> 0.6` would float on every
  # `init -upgrade`, letting an unreviewed release change the lock name, role
  # assignment names or diagnostic setting body that the `moved` blocks rely on.
  version = "0.9.0"

  location            = var.location
  diagnostic_settings = var.diagnostic_settings
  enable_telemetry    = var.enable_telemetry
  lock                = var.lock
  # Include resource-group custom roles as well as roles inherited from above.
  role_assignment_definition_scope = var.parent_id
  role_assignments                 = var.role_assignments
}

# ---------------------------------------------------------------------------
# GENESIS. Writes once, at create, when there is nothing live to drop.
# ---------------------------------------------------------------------------
resource "azapi_resource" "this" {
  location  = var.location
  name      = var.name
  parent_id = local.parent_id
  type      = var.resource_types.network_public_ip_addresses
  body      = local.public_ip_body
  # TFFR8. Collapse the empty list to null so the write-only argument is absent
  # by default. Do not add it to `ignore_changes`: AzAPI keeps it in private
  # state, and ignoring it makes the planned `output` unknown on every plan.
  ignore_body_changes = length(var.ignore_body_changes.network_public_ip_addresses) > 0 ? (
    var.ignore_body_changes.network_public_ip_addresses
  ) : null
  ignore_null_property = true
  # TFFR4. Empty on every writer: the allocated address is read by the separate
  # data source below. It is paired with `ignore_changes` on purpose. At
  # adoption the migrated state holds `null` while the config holds `[]`, and
  # without the pin that difference alone plans an update that PUTs the stale
  # `state.body`. Changing this list later needs a state operation.
  response_export_values = []
  retry                  = var.retry
  # `avm_azapi_resource_tags_required` wants the literal `var.tags`. After
  # create `tags` is ignored; every tag write goes through
  # `azapi_resource_action.tags`.
  tags = var.tags

  # AzureRM's per-resource defaults (create 30m, read 5m, update 30m, delete
  # 30m); a consumer override in `var.timeouts` replaces them.
  timeouts {
    create = local.timeouts.network_public_ip_addresses.create
    delete = local.timeouts.network_public_ip_addresses.delete
    read   = local.timeouts.network_public_ip_addresses.read
    update = local.timeouts.network_public_ip_addresses.update
  }

  # The pattern: after create this resource is inert and `azapi_update_resource`
  # below is the only body writer. Without these ignores, any later change to
  # `body` or `tags` would issue a full PUT that drops the undeclared members
  # listed at the top of this file. `lifecycle` cannot take a variable, so the
  # list is spelled out.
  #
  # Accepted costs:
  #   - Body drift on the ignored paths is invisible; the merge writer still
  #     sees drift on the four paths it declares.
  #   - Merge cannot un-set a member. Tags are replaced whole by
  #     `azapi_resource_action.tags`, and removing `domain_name_label` or
  #     `reverse_fqdn` is refused by a precondition.
  #   - Destroying `azapi_update_resource` alone makes no ARM call. Harmless:
  #     deleting this resource deletes the public IP.
  #   - `type` drift is invisible here, so the `moved` upgrade plan does not
  #     depend on the API version AzAPI picks. The satellite resources do not
  #     ignore `type`; their defaults in `var.resource_types` are pinned.
  lifecycle {
    ignore_changes = [
      body,
      identity,
      ignore_casing,
      ignore_missing_property,
      ignore_null_property,
      ignore_other_items_in_list,
      list_unique_id_property,
      locks,
      response_export_values,
      schema_validation_enabled,
      sensitive_body,
      sensitive_body_version,
      tags,
      type,
      update_headers,
      update_query_parameters,
    ]
  }
}

# ---------------------------------------------------------------------------
# DAY 2. GET, then merge, so undeclared paths are preserved rather than
# dropped. It also runs at create, so standing a public IP up costs two PUTs.
# ---------------------------------------------------------------------------
resource "azapi_update_resource" "this" {
  resource_id = azapi_resource.this.id
  type        = var.resource_types.network_public_ip_addresses
  body        = local.public_ip_update_body
  # No `ignore_body_changes`: TFFR8 lists this type, but the argument does not
  # exist on `azapi_update_resource` in azapi 2.12/2.13.
  #
  # TFFR4: empty, because nothing reads this writer's `.output`. No
  # `ignore_changes` is needed: this address is never imported, so the
  # null-vs-`[]` adoption difference cannot arise.
  response_export_values = []
  retry                  = var.retry

  timeouts {
    create = local.timeouts.network_public_ip_addresses.create
    delete = local.timeouts.network_public_ip_addresses.delete
    read   = local.timeouts.network_public_ip_addresses.read
    update = local.timeouts.network_public_ip_addresses.update
  }

  # =========================================================================
  # ForceNew guards. AzAPI cannot replace on a body property, so a change that
  # AzureRM would have turned into a replacement is an error here instead of a
  # silence.
  #
  # They live on this address, not on the full writer: that writer ignores
  # `body`, so it would plan no diff to check against. Here `body` is the state
  # body, which for a ForceNew property is the live value. Both sides of every
  # comparison are built by the same expression in `locals.tf`, so an absent
  # member is `null`/`[]` on both sides.
  #
  # Under `terraform plan -refresh=false` the migrated state body is null and
  # these fail on purpose: that plan is unsupported for this module (azapi#1227).
  # =========================================================================
  lifecycle {
    # `sku.name`
    precondition {
      condition     = local.pip_state_sku_name == local.pip_config_sku_name
      error_message = "`sku` cannot change in place: the live public IP address was created with sku \"${coalesce(local.pip_state_sku_name, "<absent>")}\" and the configuration now asks for \"${coalesce(local.pip_config_sku_name, "<absent>")}\". AzureRM marked `sku` ForceNew (public_ip_resource.go L111), so it would have REPLACED this resource -- releasing the allocated IP address. AzAPI cannot replace on a body property, so this plan is failed instead. If you really intend the replacement, and you accept that the public IP address WILL change, run terraform apply -replace='module.<path>.azapi_resource.this' deliberately."
    }
    # `sku.tier`
    precondition {
      condition     = local.pip_state_sku_tier == local.pip_config_sku_tier
      error_message = "`sku_tier` cannot change in place: the live public IP address was created with sku_tier \"${coalesce(local.pip_state_sku_tier, "<absent>")}\" and the configuration now asks for \"${coalesce(local.pip_config_sku_tier, "<absent>")}\". AzureRM marked `sku_tier` ForceNew (public_ip_resource.go L121). Run terraform apply -replace='module.<path>.azapi_resource.this' if you accept that the public IP address WILL change."
    }
    # `properties.publicIPAddressVersion`
    precondition {
      condition     = local.pip_state_ip_version == local.pip_config_ip_version
      error_message = "`ip_version` cannot change in place: the live public IP address was created as \"${coalesce(local.pip_state_ip_version, "<absent>")}\" and the configuration now asks for \"${coalesce(local.pip_config_ip_version, "<absent>")}\". AzureRM marked `ip_version` ForceNew (public_ip_resource.go L101). Run terraform apply -replace='module.<path>.azapi_resource.this' if you accept that the public IP address WILL change."
    }
    # `extendedLocation.name`
    precondition {
      condition     = local.pip_state_edge_zone == local.pip_config_edge_zone
      error_message = "`edge_zone` cannot change in place: the live public IP address was created in edge zone \"${coalesce(local.pip_state_edge_zone, "<absent>")}\" and the configuration now asks for \"${coalesce(local.pip_config_edge_zone, "<absent>")}\". AzureRM marked `edge_zone` ForceNew (public_ip_resource.go L95, commonschema.EdgeZoneOptionalForceNew). Run terraform apply -replace='module.<path>.azapi_resource.this' if you accept that the public IP address WILL change."
    }
    # `properties.publicIPPrefix.id`
    precondition {
      condition     = local.pip_state_prefix_id == local.pip_config_prefix_id
      error_message = "`public_ip_prefix_id` cannot change in place: the live public IP address was allocated from \"${coalesce(local.pip_state_prefix_id, "<absent>")}\" and the configuration now asks for \"${coalesce(local.pip_config_prefix_id, "<absent>")}\". AzureRM marked `public_ip_prefix_id` ForceNew (public_ip_resource.go L165). Run terraform apply -replace='module.<path>.azapi_resource.this' if you accept that the public IP address WILL change."
    }
    # `properties.ddosSettings.ddosProtectionPlan.id`. AzureRM's update branch
    # for this field is unreachable (the schema marks it ForceNew), so
    # replacement is the behaviour being preserved.
    precondition {
      condition     = local.pip_state_ddos_plan_id == local.pip_config_ddos_plan_id
      error_message = "`ddos_protection_plan_id` cannot change in place: the live public IP address uses \"${coalesce(local.pip_state_ddos_plan_id, "<absent>")}\" and the configuration now asks for \"${coalesce(local.pip_config_ddos_plan_id, "<absent>")}\". AzureRM marked `ddos_protection_plan_id` ForceNew (public_ip_resource.go L95). Run terraform apply -replace='module.<path>.azapi_resource.this' if you accept that the public IP address WILL change."
    }
    # `properties.ipTags`, compared as a set of `"<type>=<value>"` strings so
    # ARM's array order cannot cause a false positive.
    precondition {
      condition     = local.pip_state_ip_tags == local.pip_config_ip_tags
      error_message = "`ip_tags` cannot change in place: the live public IP address carries [${join(", ", sort(tolist(local.pip_state_ip_tags)))}] and the configuration now asks for [${join(", ", sort(tolist(local.pip_config_ip_tags)))}]. AzureRM marked `ip_tags` ForceNew (public_ip_resource.go L172). Run terraform apply -replace='module.<path>.azapi_resource.this' if you accept that the public IP address WILL change."
    }
    # Top-level `body.zones`, not under `properties`.
    precondition {
      condition     = local.pip_state_zones == local.pip_config_zones
      error_message = "`zones` cannot change in place: the live public IP address was created in availability zones [${join(", ", sort(tolist(local.pip_state_zones)))}] and the configuration now asks for [${join(", ", sort(tolist(local.pip_config_zones)))}]. AzureRM marked `zones` ForceNew (public_ip_resource.go L178, commonschema.ZonesMultipleOptionalForceNew). Run terraform apply -replace='module.<path>.azapi_resource.this' if you accept that the public IP address WILL change."
    }
    # Not a ForceNew guard. AzureRM replaced the whole DNS settings object when
    # either input changed, but a merge writer cannot remove an omitted nested
    # member, so removal of either stateful member (or a switch between them) is
    # refused.
    precondition {
      condition = (
        local.pip_state_dns_label == null || local.pip_config_dns_label != null
        ) && (
        local.pip_state_reverse_fqdn == null || local.pip_config_reverse_fqdn != null
      )
      error_message = "`domain_name_label` and `reverse_fqdn` cannot be removed or switched in place when the live public IP has that DNS member. This module's day-2 writer merges and cannot un-set an omitted nested member. Remove the member out of band, or replace the resource with terraform apply -replace='module.<path>.azapi_resource.this' if you accept that the public IP address WILL change."
    }
  }
}

# ---------------------------------------------------------------------------
# DAY 2, TAGS. `azapi_update_resource` merges, so it can add or change a tag but
# never remove one. A PUT at `Microsoft.Resources/tags/default` replaces the
# whole set, as AzureRM did.
#
# - It is an `azapi_resource_action`, not an `azapi_resource`: the tags
#   singleton always exists, so `azapi_resource` can never create it.
# - `count = var.tags != null`: AzureRM only re-PUT tags when they changed, so
#   an unconditional replace-all would delete policy-inherited tags from every
#   consumer who never set `tags`. `tags = {}` still clears them.
# - Out-of-band tags are not detected as drift: this action issues no GET.
# - `depends_on` serialises it behind the merge writer; two writes on one
#   parent return 409 `AnotherOperationInProgress`.
# ---------------------------------------------------------------------------
resource "azapi_resource_action" "tags" {
  count = var.tags != null ? 1 : 0

  method      = "PUT"
  resource_id = "${azapi_resource.this.id}/providers/Microsoft.Resources/tags/default"
  type        = var.resource_types.resources_tags
  body = {
    properties = {
      tags = local.public_ip_tags
    }
  }
  response_export_values = []
  retry                  = var.retry

  timeouts {
    create = local.timeouts.network_public_ip_addresses.create
    delete = local.timeouts.network_public_ip_addresses.delete
    read   = local.timeouts.network_public_ip_addresses.read
    update = local.timeouts.network_public_ip_addresses.update
  }

  depends_on = [azapi_update_resource.this]
}

# ---------------------------------------------------------------------------
# THE ALLOCATED ADDRESS, read-only. A data source has no writer and no
# `state.body`, so a non-empty `response_export_values` here cannot drag anything
# into an update. Do not copy it onto a writer: on `azapi_resource.this` it
# causes a stale full PUT at adoption.
#
# There is deliberately no `depends_on` on the merge writer. It would defer
# this read to apply time and make `output "public_ip_address"` unknown during
# the `moved` upgrade plan. The cost is that the output can lag one apply
# behind a change that reallocates the address; a Static address does not move.
# ---------------------------------------------------------------------------
data "azapi_resource" "this" {
  resource_id            = azapi_resource.this.id
  type                   = var.resource_types.network_public_ip_addresses
  response_export_values = ["properties.ipAddress"]
}

# ---------------------------------------------------------------------------
# MANAGEMENT LOCK. A plain single writer: the body has two members and no child
# collections, so a full PUT is parity.
#
# `name` and `notes` are not taken from `avm-utl-interfaces` unchanged, because
# the lock name is part of its resource ID and AzureRM always set both:
#   - `lock_azapi.name` is `null` when unset, while AzureRM generated
#     `lock-<kind>`. Taking the null would make the `moved` block point at a
#     different resource.
#   - `lock_azapi.body` has no `notes`; re-adding AzureRM's string keeps the
#     upgrade plan free of a body diff.
# ---------------------------------------------------------------------------
resource "azapi_resource" "lock" {
  count = var.lock != null ? 1 : 0

  name      = coalesce(module.interfaces.lock_azapi.name, "lock-${var.lock.kind}")
  parent_id = azapi_resource.this.id
  type      = var.resource_types.authorization_locks
  body = merge(module.interfaces.lock_azapi.body, {
    properties = merge(module.interfaces.lock_azapi.body.properties, {
      notes = local.lock_notes
    })
  })
  ignore_body_changes = length(var.ignore_body_changes.authorization_locks) > 0 ? (
    var.ignore_body_changes.authorization_locks
  ) : null
  ignore_null_property = true
  # Empty and ignored, as on the public IP: a null-vs-`[]` difference at
  # adoption would otherwise force a full PUT of the stale `state.body`.
  response_export_values = []
  retry                  = var.retry

  timeouts {
    create = local.timeouts.authorization_locks.create
    delete = local.timeouts.authorization_locks.delete
    read   = local.timeouts.authorization_locks.read
    update = local.timeouts.authorization_locks.update
  }

  lifecycle {
    ignore_changes = [
      response_export_values,
    ]
  }
  depends_on = [
    azapi_update_resource.this,
    azapi_resource_action.tags,
  ]
}

# ---------------------------------------------------------------------------
# ROLE ASSIGNMENTS. A plain single writer; the body comes from
# `avm-utl-interfaces`. ARM has no `skip_service_principal_aad_check` property,
# but AzureRM sent `principalType = ServicePrincipal` when it was true and
# `principal_type` was unset. That is restored below; an explicit
# `principal_type` wins.
# ---------------------------------------------------------------------------
resource "azapi_resource" "role_assignment" {
  for_each = module.interfaces.role_assignments_azapi

  # A pinned name wins. Otherwise derive one, so a replacement gets a new GUID.
  name = coalesce(
    var.role_assignments[each.key].name,
    uuidv5("url", join("|", [
      lower(azapi_resource.this.id),
      lower(each.value.body.properties.principalId),
      lower(each.value.body.properties.roleDefinitionId),
      lower(coalesce(each.value.body.properties.delegatedManagedIdentityResourceId, "-")),
    ]))
  )
  parent_id = azapi_resource.this.id
  type      = var.resource_types.authorization_role_assignments
  # Lowercase the immutable IDs so a casing-only change does not replace the assignment.
  body = merge(each.value.body, {
    properties = merge(
      each.value.body.properties,
      {
        principalId      = lower(each.value.body.properties.principalId)
        roleDefinitionId = lower(each.value.body.properties.roleDefinitionId)
      },
      each.value.body.properties.delegatedManagedIdentityResourceId == null ? {} : {
        delegatedManagedIdentityResourceId = lower(each.value.body.properties.delegatedManagedIdentityResourceId)
      },
      var.role_assignments[each.key].skip_service_principal_aad_check && var.role_assignments[each.key].principal_type == null ? {
        principalType = "ServicePrincipal"
      } : {},
    )
  })
  ignore_body_changes = length(var.ignore_body_changes.authorization_role_assignments) > 0 ? (
    var.ignore_body_changes.authorization_role_assignments
  ) : null
  # Keeps the configured casing after refresh, so Azure's casing cannot trigger a replacement.
  ignore_casing        = true
  ignore_null_property = true
  replace_triggers_refs = [
    "properties.principalId",
    "properties.roleDefinitionId",
    "properties.delegatedManagedIdentityResourceId",
  ]
  response_export_values = []
  retry                  = var.retry

  timeouts {
    create = local.timeouts.authorization_role_assignments.create
    delete = local.timeouts.authorization_role_assignments.delete
    read   = local.timeouts.authorization_role_assignments.read
    update = local.timeouts.authorization_role_assignments.update
  }

  # `name` is ignored so an adopted, server-assigned GUID stays stable
  # (`avm-tf-migration` SKILL). A replacement ignores this entry and takes the
  # derived name above, so it gets a new GUID. `response_export_values` is not
  # ignored, so the upgrade apply rewrites the adopted body under the same GUID
  # and a later in-place edit does not trip `replace_triggers_refs`.
  lifecycle {
    ignore_changes = [
      name,
    ]
  }
}

# ---------------------------------------------------------------------------
# DIAGNOSTIC SETTINGS. A plain single writer, NOT candidate 1, and that is
# deliberate: `Microsoft.Insights/diagnosticSettings` has no child collections
# and no undeclared writable members. AzureRM's own update path is likewise an
# unconditional CreateOrUpdate of a body built from scratch, so a full PUT is
# parity. The candidate-1 machinery would buy nothing and would cost the
# inability to un-set a destination.
# ---------------------------------------------------------------------------
resource "azapi_resource" "diagnostic_setting" {
  for_each = var.diagnostic_settings

  name      = local.diagnostic_setting_names[each.key]
  parent_id = azapi_resource.this.id
  type      = var.resource_types.insights_diagnostic_settings
  body      = local.diagnostic_setting_bodies[each.key]
  ignore_body_changes = length(var.ignore_body_changes.insights_diagnostic_settings) > 0 ? (
    var.ignore_body_changes.insights_diagnostic_settings
  ) : null
  # `logAnalyticsDestinationType = null` is carried for the `Dedicated` case, as
  # AzureRM did; the null prune makes that equivalent.
  ignore_null_property = true
  # Perpetual-diff fix. ARM's GET returns the complete category-group set for
  # the parent type, e.g. `{categoryGroup = "audit", enabled = false}` next to
  # the `allLogs` entry that was PUT, while `avm-utl-interfaces` (like AzureRM)
  # only emits `enabled = true` entries. These two arguments are AzAPI's answer
  # to partial list management. The composite key is needed because a
  # category-group entry has `category = null` and a log-category entry has
  # `categoryGroup = null`. `properties.metrics` is covered the same way.
  #
  # Cost: an out-of-band enable of a category this module does not manage is no
  # longer reported as drift. Changes through the module's inputs still apply.
  ignore_other_items_in_list = [
    "properties.logs",
    "properties.metrics",
  ]
  list_unique_id_property = {
    "properties.logs"    = "category, categoryGroup"
    "properties.metrics" = "category"
  }
  response_export_values = []
  retry                  = var.retry

  timeouts {
    create = local.timeouts.insights_diagnostic_settings.create
    delete = local.timeouts.insights_diagnostic_settings.delete
    read   = local.timeouts.insights_diagnostic_settings.read
    update = local.timeouts.insights_diagnostic_settings.update
  }

  lifecycle {
    ignore_changes = [
      response_export_values,
    ]
  }
}

# =============================================================================
# AzureRM -> AzAPI state moves (`avm-tf-migration` SKILL). Whole-resource moves
# with the same keys, so a consumer only bumps the module version.
#
# Plan the upgrade with a normal refresh, never `-refresh=false`: AzAPI's
# `MoveResourceState` leaves `location` null and `ModifyPlan` then plans a
# replacement (azapi#1227). A refreshing plan repairs it.
#
# The merge writer, tags action and data source have no `moved` block because
# they have no AzureRM predecessor. The upgrade adds them, so its plan is
# "N to add, N to change, 0 to destroy", not "no changes".
# =============================================================================

moved {
  from = azurerm_public_ip.this
  to   = azapi_resource.this
}

moved {
  from = azurerm_management_lock.this
  to   = azapi_resource.lock
}

moved {
  from = azurerm_role_assignment.this
  to   = azapi_resource.role_assignment
}

moved {
  from = azurerm_monitor_diagnostic_setting.this
  to   = azapi_resource.diagnostic_setting
}
