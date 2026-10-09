# ---------------------------------------------------------------------------
# Azure public IP address, migrated from `hashicorp/azurerm` to `Azure/azapi`
# IN PLACE (`avm-tf-migration` SKILL.md L16-24): same module, same
# `count`/`for_each` boundary, same keys. Only the provider and the request
# bodies moved, so a consumer bumps the module version and nothing else.
#
# THE SHAPE, in one sentence: `azapi_resource.this` creates the public IP once
# and then never PUTs again, and every subsequent write goes through
# `azapi_update_resource.this`, which GETs the live object and merges.
#
# This is the CANDIDATE-1 shape from the vWAN pattern module
# (`modules/firewall/main.tf` at `azapi-migration-phase1` cd9db05). It is used
# here, and not the simpler single-full-PUT writer, because
# `Microsoft.Network/publicIPAddresses@2025-07-01` has WRITABLE members that
# this module does not declare, and a full PUT that omits them can drop them:
#
#   path                              why it matters
#   --------------------------------  --------------------------------------
#   properties.ipAddress              the allocated address itself. Writable
#                                     (NOT `readOnly` in the 2025-07-01 type),
#                                     so omitting it from a PUT is not
#                                     obviously safe. Losing it is the worst
#                                     outcome this module has.
#   properties.natGateway             the NAT gateway association. Writable on
#                                     the PIP, so a PUT that omits it can
#                                     dissociate a public IP from a NAT
#                                     gateway that another module owns.
#   properties.linkedPublicIPAddress  IPv4/IPv6 pairing.
#   properties.servicePublicIPAddress service-linked address.
#   properties.deleteOption           NIC-cascade delete behaviour.
#   properties.dnsSettings.domainNameLabelScope
#                                     not exposed by this module's public API.
#
# `properties.ipConfiguration` is `readOnly`, so LB/NIC associations are NOT
# at risk -- ARM does not accept them on the way in.
#
# AzureRM itself never issued a full PUT of a body it built from scratch on
# day 2: `resourcePublicIpUpdate` is `payload := existing.Model` followed by
# guarded assignments (`public_ip_resource.go` L340-L410). That code IS the
# provider's statement that the undeclared members have to be carried forward.
#
# 🔴 UNMEASURED. Nothing above has been confirmed against live ARM for this
# resource type. The merge mechanism itself was measured on
# `microsoft.network/vpngateways` during the vWAN migration; the exposure
# table is read from the ARM type, not from an experiment.
# ---------------------------------------------------------------------------

# Standard AVM interfaces (lock, role assignments, diagnostic settings),
# composed rather than hand-rolled -- `avm-tf-migration` SKILL.md L103.
module "interfaces" {
  source = "Azure/avm-utl-interfaces/azure"
  # 🔴 EXACT PIN, not the SKILL's `~> 0.6`. `terraform_module_version` in the
  # pinned AVM lint configuration requires an exact version, and `~> 0.6` means
  # `>= 0.6, < 1.0` -- it was already floating to 0.7.0 on every `init
  # -upgrade`, which would let an unreviewed interfaces release change the lock
  # name, the role-assignment names or the diagnostic-setting body underneath a
  # module whose `moved` blocks depend on all three. 0.7.0 is the version this
  # migration was audited against.
  version = "0.7.0"

  diagnostic_settings = var.diagnostic_settings
  enable_telemetry    = var.enable_telemetry
  lock                = var.lock
  # The scope the module lists role definitions at, so a
  # `role_definition_id_or_name` given as a NAME still resolves. AzureRM did
  # this lookup itself; under AzAPI it costs a
  # `Microsoft.Authorization/roleDefinitions` list at plan time, and therefore
  # read permission at the subscription.
  role_assignment_definition_scope = local.parent_subscription_id
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
  # TFFR8. Collapse the empty path list to null so the write-only argument is
  # absent by default. Do not add it to lifecycle.ignore_changes: AzAPI stores
  # it in private state, and ignoring it makes the planned value unknown, which
  # in turn makes output unknown on every plan.
  ignore_body_changes = length(var.ignore_body_changes.network_public_ip_addresses) > 0 ? (
    var.ignore_body_changes.network_public_ip_addresses
  ) : null
  # Matches AzureRM's nil-pointer/`omitempty` serialisation: an optional the
  # consumer left unset is absent from the request rather than sent as an
  # explicit JSON null. `locals.tf` already builds the body with `merge()` so
  # that no null reaches here; this is belt and braces.
  ignore_null_property = true
  # ✅ TFFR4 requires the attribute on every AzAPI resource, "even if empty".
  #
  # WHY `[]` AND NOT `["properties.ipAddress"]`: the allocated address is read
  # by the SEPARATE read-only `data "azapi_resource" "this"` below, precisely so
  # that no WRITER has to carry a non-empty export list.
  #
  # 🔴 IT IS ONLY SAFE BECAUSE `ignore_changes` SILENCES IT. The attribute
  # carries no `skip_on` tag, so the provider cannot skip the external request
  # the moment plan and state differ on it -- and at ADOPTION (the `moved`
  # blocks at the foot of this file) the migrated state holds `null` while the
  # config holds `[]`. That difference alone would drag the public IP into an
  # update and PUT the stale `state.body`. NEVER declare this attribute on an
  # `azapi_resource` without the matching `ignore_changes` entry.
  #
  # 🔴 A FUTURE CHANGE TO THIS EXPORT LIST NEEDS ITS OWN MIGRATION:
  # `ignore_changes` pins the prior value, so editing the list is a no-op on an
  # already-managed public IP until a state operation is performed.
  response_export_values = []
  retry                  = var.retry
  # ✅ `avm_azapi_resource_tags_required`: "AzAPI resources that support tags
  # must set exactly `tags = var.tags`" -- the literal, not a normalised local.
  #
  # AzureRM's `tags.Expand(nil)` returned a pointer to an EMPTY map and never
  # nil, so an untagged public IP was created with `"tags": {}`, whereas this
  # sends no `tags` member at all. Immaterial in both directions: ARM treats an
  # absent `tags` on create exactly as it treats `{}`, and `tags` is in the
  # `ignore_changes` list below, so after create this attribute is inert and
  # every tag write goes through `azapi_resource_action.tags`.
  tags = var.tags

  # `public_ip_resource.go` L50-L53 -- AzureRM's own per-resource defaults:
  # Create 30m, Read 5m, Update 30m, Delete 30m. A consumer override in
  # `var.timeouts` replaces them; see `local.timeouts`.
  #
  # A static block rather than `dynamic "timeouts"`: `var.timeouts` is
  # `nullable = false` with a `{}` default, so a `dynamic` wrapper would always
  # emit exactly one block and is a no-op.
  timeouts {
    create = local.timeouts.network_public_ip_addresses.create
    delete = local.timeouts.network_public_ip_addresses.delete
    read   = local.timeouts.network_public_ip_addresses.read
    update = local.timeouts.network_public_ip_addresses.update
  }

  # ⭐ THE ENTIRE PATTERN IS THIS BLOCK.
  #
  # Without it, any later change to `body` or `tags` makes THIS resource issue
  # a full PUT of the configured body -- which omits every row in the exposure
  # table at the top of this file. With it, this address goes inert after
  # create and the merge writer below becomes the only body writer.
  #
  # The list is audited against azapi's `AzapiResourceModel`; it is the same
  # list the vWAN pattern module uses. `lifecycle` cannot take a variable, so
  # it is spelled out.
  #
  # 🔴 COSTS ACCEPTED HERE:
  #   (a) body drift on every path this file stops watching is PERMANENTLY
  #       invisible. The merge writer still sees drift on the four paths IT
  #       declares and nowhere else.
  #   (b) merge is additive -- it CANNOT un-set. Tags are handled by
  #       `azapi_resource_action.tags` below, which REPLACES the whole set;
  #       removing a previously-set `domain_name_label` / `reverse_fqdn` is
  #       refused by a precondition rather than silently ignored.
  #   (c) `azapi_update_resource.Delete` is an empty function: destroying the
  #       merge writer on its own makes no ARM call. Harmless here, because
  #       destroying this address deletes the public IP and everything with it.
  #   (d) `type` drift is invisible on this address. That is deliberate: it is
  #       what makes the `moved` upgrade plan immune to the API-version that
  #       `azapi`'s `MoveResourceState` picks. The satellite resources below do
  #       NOT ignore `type`, which is why their defaults in
  #       `var.resource_types` are pinned to the newest embedded versions.
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
# DAY 2. GET-then-merge, so an undeclared path is PRESERVED rather than
# dropped. Carries only the members AzureRM's own update path could assign.
#
# 🔴 This resource also runs at CREATE time -- `azapi_update_resource.Create`
# is a GET + merge + PUT -- so standing a public IP up costs two PUTs. That is
# inherent to the shape, not a bug in this module.
# ---------------------------------------------------------------------------
resource "azapi_update_resource" "this" {
  resource_id = azapi_resource.this.id
  type        = var.resource_types.network_public_ip_addresses
  body        = local.public_ip_update_body
  # 🔴 NO `ignore_body_changes` HERE, AND IT IS NOT AN OVERSIGHT. TFFR8 lists
  # `azapi_update_resource` among the types that trigger the requirement, but
  # the argument does not exist on that resource in azapi 2.12/2.13 --
  # `AzapiUpdateResourceModel` has `ignore_casing`, `ignore_missing_property`,
  # `ignore_other_items_in_list` and `list_unique_id_property` and no
  # `ignore_body_changes`. Writing it would be an "Unsupported argument" error
  # at validate time. The conflict is reported upward rather than worked
  # around; wire it to a sibling key if a later azapi release adds it.
  #
  # ✅ TFFR4. `[]` is correct -- nothing reads this writer's `.output`; the
  # allocated address comes from the read-only data source below. No
  # `ignore_changes` here: this address is never imported, so it is always
  # created fresh and the null-vs-`[]` adoption difference cannot arise.
  response_export_values = []

  # Same AzureRM defaults as the full writer.
  timeouts {
    create = local.timeouts.network_public_ip_addresses.create
    delete = local.timeouts.network_public_ip_addresses.delete
    read   = local.timeouts.network_public_ip_addresses.read
    update = local.timeouts.network_public_ip_addresses.update
  }

  # =========================================================================
  # ⭐ FORCENEW GUARDS. The replacement AzAPI cannot perform, turned into an
  # error instead of a silence.
  #
  # WHY HERE AND NOT ON THE FULL WRITER: the full writer's
  # `ignore_changes = [body]` makes a changed `sku` or `zones` produce NO diff
  # on that address, so a precondition there would be evaluated against a plan
  # that already agrees with itself. This address re-plans on every apply.
  #
  # WHY IT IS RELIABLE: `azapi_resource.this.body` is the STATE body, pinned by
  # `ignore_changes = [body]`. For a property AzureRM marked ForceNew that is
  # exactly the right reference point -- such a property cannot legally change
  # without a replacement, so the create/import-time value IS the live value.
  #
  # BOTH HALVES OF EVERY COMPARISON ARE BUILT BY THE SAME EXPRESSION in
  # `locals.tf`, so an absent member is `null`/`[]` on both sides and a
  # non-zonal, prefix-less, edge-zone-less public IP passes every check.
  #
  # ⚠️ UNDER `terraform plan -refresh=false` the migrated state body is null,
  # every state-side local collapses to `null`/`[]`, and these preconditions
  # FAIL. That is the intended outcome: `-refresh=false` is not a supported
  # upgrade plan for this module (azapi#1227), and failing here is strictly
  # better than the silent replacement that issue produces.
  # =========================================================================
  lifecycle {
    # sku (`public_ip_resource.go` L111) at `sku.name`.
    precondition {
      condition     = local.pip_state_sku_name == local.pip_config_sku_name
      error_message = "`sku` cannot change in place: the live public IP address was created with sku \"${coalesce(local.pip_state_sku_name, "<absent>")}\" and the configuration now asks for \"${coalesce(local.pip_config_sku_name, "<absent>")}\". AzureRM marked `sku` ForceNew (public_ip_resource.go L111), so it would have REPLACED this resource -- releasing the allocated IP address. AzAPI cannot replace on a body property, so this plan is failed instead. If you really intend the replacement, and you accept that the public IP address WILL change, run terraform apply -replace='module.<path>.azapi_resource.this' deliberately."
    }
    # sku_tier (L121) at `sku.tier`.
    precondition {
      condition     = local.pip_state_sku_tier == local.pip_config_sku_tier
      error_message = "`sku_tier` cannot change in place: the live public IP address was created with sku_tier \"${coalesce(local.pip_state_sku_tier, "<absent>")}\" and the configuration now asks for \"${coalesce(local.pip_config_sku_tier, "<absent>")}\". AzureRM marked `sku_tier` ForceNew (public_ip_resource.go L121). Run terraform apply -replace='module.<path>.azapi_resource.this' if you accept that the public IP address WILL change."
    }
    # ip_version (L101) at `properties.publicIPAddressVersion`.
    precondition {
      condition     = local.pip_state_ip_version == local.pip_config_ip_version
      error_message = "`ip_version` cannot change in place: the live public IP address was created as \"${coalesce(local.pip_state_ip_version, "<absent>")}\" and the configuration now asks for \"${coalesce(local.pip_config_ip_version, "<absent>")}\". AzureRM marked `ip_version` ForceNew (public_ip_resource.go L101). Run terraform apply -replace='module.<path>.azapi_resource.this' if you accept that the public IP address WILL change."
    }
    # edge_zone (commonschema.EdgeZoneOptionalForceNew, L95) at
    # `extendedLocation.name`.
    precondition {
      condition     = local.pip_state_edge_zone == local.pip_config_edge_zone
      error_message = "`edge_zone` cannot change in place: the live public IP address was created in edge zone \"${coalesce(local.pip_state_edge_zone, "<absent>")}\" and the configuration now asks for \"${coalesce(local.pip_config_edge_zone, "<absent>")}\". AzureRM marked `edge_zone` ForceNew (public_ip_resource.go L95, commonschema.EdgeZoneOptionalForceNew). Run terraform apply -replace='module.<path>.azapi_resource.this' if you accept that the public IP address WILL change."
    }
    # public_ip_prefix_id (L165) at `properties.publicIPPrefix.id`.
    precondition {
      condition     = local.pip_state_prefix_id == local.pip_config_prefix_id
      error_message = "`public_ip_prefix_id` cannot change in place: the live public IP address was allocated from \"${coalesce(local.pip_state_prefix_id, "<absent>")}\" and the configuration now asks for \"${coalesce(local.pip_config_prefix_id, "<absent>")}\". AzureRM marked `public_ip_prefix_id` ForceNew (public_ip_resource.go L165). Run terraform apply -replace='module.<path>.azapi_resource.this' if you accept that the public IP address WILL change."
    }
    # ddos_protection_plan_id (L95) at
    # `properties.ddosSettings.ddosProtectionPlan.id`. AzureRM has an update
    # branch for this field, but the schema marks it ForceNew, so that branch
    # is unreachable and replacement is the behaviour being preserved.
    precondition {
      condition     = local.pip_state_ddos_plan_id == local.pip_config_ddos_plan_id
      error_message = "`ddos_protection_plan_id` cannot change in place: the live public IP address uses \"${coalesce(local.pip_state_ddos_plan_id, "<absent>")}\" and the configuration now asks for \"${coalesce(local.pip_config_ddos_plan_id, "<absent>")}\". AzureRM marked `ddos_protection_plan_id` ForceNew (public_ip_resource.go L95). Run terraform apply -replace='module.<path>.azapi_resource.this' if you accept that the public IP address WILL change."
    }
    # ip_tags (L172) at `properties.ipTags`. Compared as a set of
    # `"<type>=<value>"` strings so ARM's array ordering cannot cause a false
    # positive.
    precondition {
      condition     = local.pip_state_ip_tags == local.pip_config_ip_tags
      error_message = "`ip_tags` cannot change in place: the live public IP address carries [${join(", ", sort(tolist(local.pip_state_ip_tags)))}] and the configuration now asks for [${join(", ", sort(tolist(local.pip_config_ip_tags)))}]. AzureRM marked `ip_tags` ForceNew (public_ip_resource.go L172). Run terraform apply -replace='module.<path>.azapi_resource.this' if you accept that the public IP address WILL change."
    }
    # zones (commonschema.ZonesMultipleOptionalForceNew, L178) at TOP-LEVEL
    # `body.zones`, NOT under `properties`.
    precondition {
      condition     = local.pip_state_zones == local.pip_config_zones
      error_message = "`zones` cannot change in place: the live public IP address was created in availability zones [${join(", ", sort(tolist(local.pip_state_zones)))}] and the configuration now asks for [${join(", ", sort(tolist(local.pip_config_zones)))}]. AzureRM marked `zones` ForceNew (public_ip_resource.go L178, commonschema.ZonesMultipleOptionalForceNew). Run terraform apply -replace='module.<path>.azapi_resource.this' if you accept that the public IP address WILL change."
    }
    # 🔴 NOT A FORCENEW GUARD -- a merge-writer limitation guard.
    # AzureRM replaced the complete DNS settings object whenever either input
    # changed. A merge writer cannot remove an omitted nested member, so refuse
    # removal of either stateful member, including a switch between the inputs.
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
# DAY 2 -- THE TAG WRITER.
#
# 🔴 WHY A SEPARATE RESOURCE AT ALL. `azapi_update_resource` is a MERGE writer,
# and the merge preserves every undeclared key of the LIVE object, so it can
# add a tag and change a tag but can NEVER REMOVE one -- dropping a key from
# `var.tags` would produce a PUT that silently re-sent the live tag, a
# regression against azurerm 4.x where `payload.Tags = tags.Expand(...)`
# assigned the WHOLE map (public_ip_resource.go L404-L406). A PUT at
# `Microsoft.Resources/tags/default` REPLACES the whole tag set instead.
#
# 🔴 WHY `azapi_resource_action` AND NOT `azapi_resource`.
# `Microsoft.Resources/tags/default` is an ARM SINGLETON THAT ALWAYS EXISTS, so
# `azapi_resource` can never CREATE it. Do not "improve" this back into an
# `azapi_resource`.
#
# 🔴 WHY `count = var.tags != null ? 1 : 0`. AzureRM re-PUT tags only on
# `d.HasChanges("tags")`, so a consumer who never set `tags` never had their
# tags touched after create. An UNCONDITIONAL replace-all PUT would delete
# policy-inherited tags from every such consumer's public IP on the first apply
# after the upgrade. `tags = {}` (non-null, empty) still clears them, which is
# what AzureRM did.
#
# ⚠️ OUT-OF-BAND TAGS ARE NOT DETECTED: this resource's Read issues no GET, so
# a tag set outside Terraform never appears as drift. When this action is
# created or updated it replaces the complete tag set, but an unrelated apply
# does not necessarily execute it.
#
# 🔴 WHY `depends_on`. Two writes racing on one parent produce a 409
# `AnotherOperationInProgress`. `depends_on` serialises them.
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
  # ✅ TFFR4: declared on every AzAPI resource, "even if empty".
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
# THE ALLOCATED ADDRESS, read-only.
#
# 🔴 WHY A `.output` IS ALLOWED HERE AND NOWHERE ELSE IN THIS MODULE: a data
# source HAS NO WRITER. It never PUTs, it has no `state.body`, and
# `response_export_values` on it cannot drag anything into an update -- so the
# adoption hazard that governs the attribute on `azapi_resource.this` simply
# does not exist on this address.
#
# 🟡 NO `depends_on` ON THE MERGE WRITER, deliberately. Adding one would defer
# this read to apply time on every change and push an unknown through
# `output "public_ip_address"`. Without it the read depends only on
# `azapi_resource.this.id`, which is stable after create -- and, critically, is
# already KNOWN on the `moved` upgrade plan, so the output does not go unknown
# during the migration. THE COST: after a change that reallocates the address
# the output is one apply behind. A Static public IP's address does not move.
#
# ⛔ DO NOT "generalise" this non-empty export list onto a writer. Giving
# `azapi_resource.this` a non-empty `response_export_values` is what causes the
# stale full PUT at adoption.
# ---------------------------------------------------------------------------
data "azapi_resource" "this" {
  resource_id            = azapi_resource.this.id
  type                   = var.resource_types.network_public_ip_addresses
  response_export_values = ["properties.ipAddress"]
}

# ---------------------------------------------------------------------------
# MANAGEMENT LOCK. A plain single writer, NOT candidate 1.
# `Microsoft.Authorization/locks` has a two-member body and no child
# collections, so a full PUT is parity rather than a hazard.
#
# `name` and `notes` are NOT taken from `avm-utl-interfaces` unchanged:
#   - `lock_azapi.name` is `null` when the consumer did not set one, while the
#     AzureRM implementation generated `lock-<kind>`. The lock's NAME is part
#     of its resource ID, so taking the interfaces value would make the `moved`
#     block below point at a different resource.
#   - `lock_azapi.body` has no `notes`, while the AzureRM implementation always
#     set one. Re-adding it keeps the upgrade plan free of a body diff.
# ---------------------------------------------------------------------------
resource "azapi_resource" "lock" {
  count = var.lock != null ? 1 : 0

  name      = coalesce(module.interfaces.lock_azapi.name, "lock-${var.lock.kind}")
  parent_id = azapi_resource.this.id
  type      = var.resource_types.authorization_locks
  body = merge(module.interfaces.lock_azapi.body, {
    properties = merge(module.interfaces.lock_azapi.body.properties, {
      # A consumer-supplied note wins; otherwise the AzureRM string is restored
      # verbatim, because `avm-utl-interfaces` leaves `notes` null and AzureRM
      # always set one -- taking the null would put an avoidable lock-body diff
      # on the upgrade plan.
      notes = local.lock_notes
    })
  })
  ignore_body_changes = length(var.ignore_body_changes.authorization_locks) > 0 ? (
    var.ignore_body_changes.authorization_locks
  ) : null
  ignore_null_property = true
  # ✅ TFFR4, paired with the `ignore_changes` entry below for the same reason
  # as the public IP: the attribute is non-skippable, and a null-vs-`[]`
  # difference at adoption would otherwise force a full PUT of the stale
  # `state.body`.
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
}

# ---------------------------------------------------------------------------
# ROLE ASSIGNMENTS. A plain single writer; the body comes from
# `avm-utl-interfaces`, with AzureRM's `skip_service_principal_aad_check`
# request-body compatibility fallback restored below.
#
# ⚠️ ARM has no request property named `skip_service_principal_aad_check`.
# AzureRM also used this flag to send `principalType = ServicePrincipal` when
# `principal_type` was unset. Preserve that behavior; an explicit
# `principal_type` remains authoritative. Retry behavior is configured through
# `var.retry`.
# ---------------------------------------------------------------------------
resource "azapi_resource" "role_assignment" {
  for_each = module.interfaces.role_assignments_azapi

  name      = each.value.name
  parent_id = azapi_resource.this.id
  type      = var.resource_types.authorization_role_assignments
  body = merge(each.value.body, {
    properties = merge(
      each.value.body.properties,
      var.role_assignments[each.key].skip_service_principal_aad_check && var.role_assignments[each.key].principal_type == null ? {
        principalType = "ServicePrincipal"
      } : {},
    )
  })
  ignore_body_changes = length(var.ignore_body_changes.authorization_role_assignments) > 0 ? (
    var.ignore_body_changes.authorization_role_assignments
  ) : null
  ignore_null_property   = true
  response_export_values = []
  retry                  = var.retry

  timeouts {
    create = local.timeouts.authorization_role_assignments.create
    delete = local.timeouts.authorization_role_assignments.delete
    read   = local.timeouts.authorization_role_assignments.read
    update = local.timeouts.authorization_role_assignments.update
  }

  # 🔴 `name` IS IGNORED, and that is the single most important line in this
  # resource. `avm-tf-migration` SKILL.md L107-L117 blesses exactly this case:
  # "a migration case where an imported server-assigned role-assignment name
  # must remain stable".
  #
  # An existing `azurerm_role_assignment` has a SERVER-ASSIGNED GUID name.
  # `avm-utl-interfaces` generates a fresh `random_uuid` when the consumer did
  # not pin one, and `name` forces replacement on `azapi_resource`, so without
  # this entry EVERY migrated role assignment would be DESTROYED AND RECREATED
  # by the upgrade plan. With it, the migrated name is kept and only genuinely
  # new assignments take the generated UUID.
  #
  # A consumer who wants to pin a name can now set `role_assignments[*].name`;
  # on an already-migrated assignment that is a no-op until the address is
  # replaced.
  lifecycle {
    ignore_changes = [
      name,
      response_export_values,
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
  # Carries `logAnalyticsDestinationType = null` for the `Dedicated` case, which
  # is how AzureRM behaved; the prune is what makes that equivalent.
  ignore_null_property = true
  # 🔴 PERPETUAL-DIFF FIX (was D-7). ARM's GET on a diagnostic setting returns
  # the COMPLETE category-group set for the parent resource type, not just the
  # entries that were PUT. Measured on `Microsoft.Network/publicIPAddresses`:
  # the PUT response echoes only `{categoryGroup = "allLogs", enabled = true}`,
  # but the very next GET returns that PLUS
  # `{categoryGroup = "audit", enabled = false}` -- because
  # `.../diagnosticSettingsCategories` reports `categoryGroups = ["audit",
  # "allLogs"]` for this type. `avm-utl-interfaces` (by design, and matching
  # what AzureRM PUT) only ever emits `enabled = true` entries, so the extra
  # response-only element is permanent drift: `azapi_resource` compares list
  # members element-by-element and nothing else in this block suppresses it.
  # AzureRM was idempotent here only because its READ discarded the disabled
  # entries client-side.
  #
  # These two arguments are the provider's own answer to exactly this shape
  # ("partial list management"), and `list_unique_id_property`'s documentation
  # names `"category, categoryGroup"` as its worked example. The composite key
  # is required: a category-group entry has `category = null` and a
  # log-category entry has `categoryGroup = null`, so neither field alone
  # identifies an element. `properties.metrics` is covered for the same reason
  # -- a consumer setting `metric_categories = []` sends no `metrics` while ARM
  # still returns `AllMetrics` disabled.
  #
  # Cost, documented rather than hidden: an out-of-band ENABLE of a category
  # this module does not manage is no longer reported as drift. A change made
  # through the module's own inputs still plans and applies normally, because
  # `body` itself is configuration.
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
# AzureRM -> AzAPI state moves (`avm-tf-migration` SKILL.md L66-78)
#
# The provider migration is IN PLACE: same module, same `count`/`for_each`
# boundary, same keys, so every move is a whole-resource move and the consumer
# only bumps the module version.
#
# 🔴 PLAN WITH A NORMAL REFRESH. Do not use `terraform plan -refresh=false` for
# the upgrade. AzAPI's `MoveResourceState` writes only ID, Name, ParentID and
# Type, leaving `location` null, and `ModifyPlan` then reads that null and
# marks the resource for REPLACEMENT. A refreshing plan repairs it -- the Read
# backfills `location` and re-flattens `body` once. This was measured on a
# PUBLIC IP (azapi#1227): refreshing plan `0 to add, 2 to change, 0 to destroy`;
# `-refresh=false` `1 to add, 1 to change, 1 to destroy` with
# `+ location = "eastus" # forces replacement`. The supported state migration
# path is the in-module `moved` blocks below; sovereign-cloud behavior has not
# been established by that public-cloud measurement.
#
# 🔴 THE MERGE WRITER, THE TAGS ACTION AND THE READ-ONLY DATA SOURCE HAVE NO
# `moved` BLOCK because they have no AzureRM predecessor. They are ADDED by the
# upgrade, which is why the upgrade plan is "N to add, N to change, 0 to
# destroy" and not "no changes".
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
