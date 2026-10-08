# The request bodies and the writer split, pinned against the AzureRM
# behaviour they replace.
#
# Everything here runs `command = plan` against mocked providers: no Azure
# contact, and every value asserted on is either a local or a planned attribute
# that is already known without one.

mock_provider "azapi" {
  # 🔴 LOAD-BEARING. The azapi provider's SCHEMA-LEVEL validation still runs
  # under a mock, and `azapi_update_resource.resource_id` /
  # `data.azapi_resource.resource_id` both reject an ID that does not start
  # with `/`. A generated mock ID is a bare random string, so without this
  # default every `command = apply` run fails with "invalid resource ID".
  mock_resource "azapi_resource" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/publicIPAddresses/pip-unit-test"
    }
  }
  # Consumed only by `main.telemetry.tf` (`data.azapi_client_config.telemetry`,
  # gated on `var.enable_telemetry`). The functional path derives nothing from
  # a provider: the parent scope comes whole from `var.parent_id`. Fixed rather
  # than generated so any run that turns telemetry on reads plainly.
  mock_data "azapi_client_config" {
    defaults = {
      subscription_id = "00000000-0000-0000-0000-000000000000"
      tenant_id       = "11111111-1111-1111-1111-111111111111"
    }
  }
  # `avm-utl-interfaces` resolves a role definition NAME through this data
  # source. A generated mock leaves `output` null and the child module's
  # `for res in ...output.results` fails, so it is supplied explicitly.
  mock_data "azapi_resource_list" {
    defaults = {
      output = {
        results = [
          {
            id        = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7"
            role_name = "Reader"
          },
        ]
      }
    }
  }
}
mock_provider "modtm" {}
mock_provider "random" {}

variables {
  enable_telemetry = false
  location         = "eastus"
  name             = "pip-unit-test"
  parent_id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test"
}

# ---------------------------------------------------------------------------
# THE GENESIS BODY. What AzureRM's CREATE sent, member for member.
# ---------------------------------------------------------------------------
run "genesis_body_matches_the_azurerm_create_at_defaults" {
  command = plan

  assert {
    condition     = join(",", sort(keys(local.public_ip_body))) == "properties,sku,zones"
    error_message = "At module defaults the create body must carry exactly sku, properties and zones. An extra top-level member means something is being sent that AzureRM did not send; a missing one is a behaviour regression."
  }

  assert {
    condition     = join(",", sort(keys(local.public_ip_body.properties))) == "ddosSettings,idleTimeoutInMinutes,publicIPAddressVersion,publicIPAllocationMethod"
    error_message = "At module defaults, properties must carry exactly the four members AzureRM always sent. dnsSettings, publicIPPrefix and ipTags are conditional and must be ABSENT when unset, not present-and-null -- azapi would otherwise merge an explicit JSON null."
  }

  assert {
    condition     = local.public_ip_body.sku.name == "Standard" && local.public_ip_body.sku.tier == "Regional"
    error_message = "The default SKU must stay Standard/Regional across the migration."
  }

  assert {
    condition     = local.public_ip_body.properties.publicIPAllocationMethod == "Static" && local.public_ip_body.properties.publicIPAddressVersion == "IPv4" && local.public_ip_body.properties.idleTimeoutInMinutes == 4
    error_message = "The default allocation method, IP version and idle timeout must stay unchanged across the migration."
  }

  # AzureRM always sent ddosSettings.protectionMode, and attached the plan only
  # when an ID was supplied.
  assert {
    condition     = join(",", sort(keys(local.public_ip_body.properties.ddosSettings))) == "protectionMode"
    error_message = "With no ddos_protection_plan_id, ddosSettings must carry protectionMode ONLY. An empty ddosProtectionPlan object is not what AzureRM sent."
  }

  # 🔴 ARM types `zones` as an array of STRINGS while this module's public API
  # is `set(number)`. `jsonencode` is used deliberately: a `==` comparison
  # would convert and pass even if the body held numbers.
  assert {
    condition     = jsonencode(local.public_ip_body.zones) == "[\"1\",\"2\",\"3\"]"
    error_message = "body.zones must be an array of STRINGS at the TOP LEVEL of the body (not under properties). Numbers are rejected by ARM, and a `==` test would not have caught it."
  }

  # `tags.Expand(nil)` in AzureRM returns an EMPTY map, never nil.
  assert {
    condition     = local.public_ip_tags != null && length(local.public_ip_tags) == 0
    error_message = "An unset tags input must normalise to an empty map, matching AzureRM's tags.Expand(nil)."
  }
}

run "conditional_body_members_appear_only_when_configured" {
  command = plan

  variables {
    domain_name_label       = "pip-unit-test"
    reverse_fqdn            = "example.contoso.com."
    edge_zone               = "microsoftlosangeles1"
    ddos_protection_plan_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/ddosProtectionPlans/ddos-test"
    public_ip_prefix_id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/publicIPPrefixes/prefix-test"
    ip_tags                 = { RoutingPreference = "Internet" }
    zones                   = []
  }

  assert {
    condition     = join(",", sort(keys(local.public_ip_body))) == "extendedLocation,properties,sku"
    error_message = "extendedLocation must appear when edge_zone is set, and zones must be ABSENT when the zones input is empty (AzureRM omitted the member rather than sending an empty array)."
  }

  assert {
    condition     = local.public_ip_body.extendedLocation.type == "EdgeZone"
    error_message = "extendedLocation.type must be the literal EdgeZone, as AzureRM's commonschema.ExpandEdgeZoneModel produced."
  }

  assert {
    condition     = join(",", sort(keys(local.public_ip_body.properties))) == "ddosSettings,dnsSettings,idleTimeoutInMinutes,ipTags,publicIPAddressVersion,publicIPAllocationMethod,publicIPPrefix"
    error_message = "Every conditional properties member must appear once its input is supplied."
  }

  assert {
    condition     = local.public_ip_body.properties.dnsSettings.domainNameLabel == "pip-unit-test" && local.public_ip_body.properties.dnsSettings.reverseFqdn == "example.contoso.com."
    error_message = "dnsSettings must carry both members when both inputs are set."
  }

  # A map input becomes an ARM array of `{ipTagType, tag}` objects.
  assert {
    condition     = jsonencode(local.public_ip_body.properties.ipTags) == "[{\"ipTagType\":\"RoutingPreference\",\"tag\":\"Internet\"}]"
    error_message = "ip_tags must be projected from a map into ARM's array of {ipTagType, tag} objects."
  }

  assert {
    condition     = local.public_ip_body.properties.ddosSettings.ddosProtectionPlan.id == var.ddos_protection_plan_id
    error_message = "ddos_protection_plan_id must be nested at properties.ddosSettings.ddosProtectionPlan.id."
  }

  assert {
    condition     = local.public_ip_body.properties.publicIPPrefix.id == var.public_ip_prefix_id
    error_message = "public_ip_prefix_id must be nested at properties.publicIPPrefix.id."
  }
}

run "dns_settings_is_built_from_either_input_alone" {
  command = plan

  variables {
    reverse_fqdn = "example.contoso.com."
  }

  assert {
    condition     = join(",", keys(local.public_ip_body.properties.dnsSettings)) == "reverseFqdn"
    error_message = "With only reverse_fqdn set, dnsSettings must carry reverseFqdn alone -- domainNameLabel must be ABSENT, not null. The day-2 writer MERGES, so a null there would be sent to ARM as an explicit null."
  }
}

# ---------------------------------------------------------------------------
# THE DAY-2 MERGE BODY. Only what AzureRM's `resourcePublicIpUpdate` could
# assign, and nothing that it marked ForceNew.
# ---------------------------------------------------------------------------
run "update_body_carries_only_the_non_forcenew_members" {
  command = plan

  assert {
    condition     = join(",", sort(keys(local.public_ip_update_body))) == "properties"
    error_message = "The merge body must touch properties only. A top-level sku or zones member here would be sent to ARM on every day-2 apply, which is exactly the ForceNew change the preconditions exist to refuse."
  }

  assert {
    condition     = join(",", sort(keys(local.public_ip_update_body.properties))) == "ddosSettings,idleTimeoutInMinutes,publicIPAllocationMethod"
    error_message = "The merge body must carry exactly the members public_ip_resource.go L340-L410 could assign: publicIPAllocationMethod, idleTimeoutInMinutes and ddosSettings.protectionMode (plus dnsSettings when configured)."
  }

  assert {
    condition     = join(",", keys(local.public_ip_update_body.properties.ddosSettings)) == "protectionMode"
    error_message = "The merge body must carry ddosSettings.protectionMode ONLY. ddos_protection_plan_id is ForceNew in AzureRM, so sending it on the merge path would silently diverge from the guard that refuses to change it."
  }

  # 🔴 TAGS ARE NOT IN THE MERGE BODY, ON PURPOSE. A merge preserves undeclared
  # keys of the LIVE object, so it can add and change a tag but can never
  # REMOVE one. Tags go through `azapi_resource_action.tags`, which PUTs the
  # whole set at `Microsoft.Resources/tags/default`.
  assert {
    condition     = !can(local.public_ip_update_body.tags)
    error_message = "tags must NOT be in the merge body. A merge writer cannot remove a tag key, so routing tags through it silently breaks tag removal -- a regression against azurerm 4.x, which assigned the whole map."
  }
}

run "update_body_gains_dns_settings_when_configured" {
  command = plan

  variables {
    domain_name_label = "pip-unit-test"
  }

  assert {
    condition     = join(",", sort(keys(local.public_ip_update_body.properties))) == "ddosSettings,dnsSettings,idleTimeoutInMinutes,publicIPAllocationMethod"
    error_message = "dnsSettings must be assignable on the day-2 path -- AzureRM's update could set it."
  }
}

# ---------------------------------------------------------------------------
# TFFR4. The attribute is declared on every AzAPI resource, and declared EMPTY,
# because the only `.output` this module reads comes from the READ-ONLY data
# source.
# ---------------------------------------------------------------------------
run "every_writer_declares_an_empty_export_list" {
  command = plan

  variables {
    lock = { kind = "CanNotDelete" }
    tags = { scenario = "unit" }
    diagnostic_settings = {
      this = {
        workspace_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.OperationalInsights/workspaces/law-test"
      }
    }
  }

  assert {
    condition = (
      azapi_resource.this.response_export_values != null && length(azapi_resource.this.response_export_values) == 0 &&
      azapi_update_resource.this.response_export_values != null && length(azapi_update_resource.this.response_export_values) == 0 &&
      azapi_resource_action.tags[0].response_export_values != null && length(azapi_resource_action.tags[0].response_export_values) == 0 &&
      azapi_resource.lock[0].response_export_values != null && length(azapi_resource.lock[0].response_export_values) == 0 &&
      azapi_resource.diagnostic_setting["this"].response_export_values != null && length(azapi_resource.diagnostic_setting["this"].response_export_values) == 0
    )
    error_message = "TFFR4 is Severity-MUST: response_export_values must be declared on every AzAPI resource, and this module declares it EMPTY on every WRITER. A non-empty list on a writer is what drags an adopted resource into an update and PUTs its stale state.body."
  }

  # The one non-empty list in the module, and it is on a data source, which has
  # no writer and therefore no adoption hazard.
  assert {
    condition     = join(",", data.azapi_resource.this.response_export_values) == "properties.ipAddress"
    error_message = "The allocated IP address must be read through the read-only data source, not exported from a writer."
  }
}

# ---------------------------------------------------------------------------
# THE TAG WRITER.
# ---------------------------------------------------------------------------
run "tag_writer_is_absent_when_tags_are_unset" {
  command = plan

  variables {
    tags = null
  }

  assert {
    condition     = length(azapi_resource_action.tags) == 0
    error_message = "With tags unset the tag writer must not exist. AzureRM only re-PUT tags on d.HasChanges(\"tags\"), so an unconditional replace-all PUT would strip policy-inherited tags from every untagged consumer on the first apply after the upgrade."
  }
}

run "tag_writer_replaces_the_whole_set_at_the_tags_singleton" {
  # `command = apply` rather than `plan`: `resource_id` is derived from
  # `azapi_resource.this.id`, which is unknown until the public IP exists.
  command = apply

  variables {
    tags = { scenario = "unit", owner = "avm" }
  }

  assert {
    condition     = length(azapi_resource_action.tags) == 1
    error_message = "With tags set the tag writer must exist."
  }

  assert {
    condition     = azapi_resource_action.tags[0].method == "PUT"
    error_message = "The tag write must be a PUT. A PATCH would merge, and merging cannot remove a tag key."
  }

  assert {
    condition     = endswith(azapi_resource_action.tags[0].resource_id, "/providers/Microsoft.Resources/tags/default")
    error_message = "The tag write must target the Microsoft.Resources/tags/default singleton on the public IP address."
  }

  assert {
    condition     = jsonencode(azapi_resource_action.tags[0].body.properties.tags) == jsonencode(var.tags)
    error_message = "The tag writer must send the whole configured tag map, so that removing a key from var.tags removes it from Azure."
  }

  # `avm_azapi_resource_tags_required` requires the LITERAL `tags = var.tags`
  # on the create-only writer, not a normalised local. Pinned here so the
  # normalisation cannot creep back in.
  assert {
    condition     = jsonencode(azapi_resource.this.tags) == jsonencode(var.tags)
    error_message = "azapi_resource.this must set exactly `tags = var.tags` (avm_azapi_resource_tags_required)."
  }
}

run "an_empty_tag_map_still_clears_tags" {
  command = plan

  variables {
    tags = {}
  }

  assert {
    condition     = length(azapi_resource_action.tags) == 1 && length(azapi_resource_action.tags[0].body.properties.tags) == 0
    error_message = "tags = {} is NOT the same as tags = null: an explicit empty map must still produce a replace-all PUT that clears every tag, which is what AzureRM did."
  }
}

run "a_tag_action_uses_the_consumer_timeouts" {
  command = plan

  variables {
    tags = { scenario = "unit" }
    timeouts = {
      create = "3m"
      read   = "1m"
      update = "4m"
      delete = "2m"
    }
  }

  assert {
    condition = (
      azapi_resource_action.tags[0].timeouts.create == "3m" &&
      azapi_resource_action.tags[0].timeouts.read == "1m" &&
      azapi_resource_action.tags[0].timeouts.update == "4m" &&
      azapi_resource_action.tags[0].timeouts.delete == "2m"
    )
    error_message = "The tag action must receive all consumer timeout overrides."
  }
}

run "transitioning_tags_to_null_does_not_issue_a_clear" {
  command   = apply
  state_key = "tags_to_null"

  variables {
    tags = { managed = "value" }
  }
}

run "null_tags_remove_the_writer_without_clearing_the_remote_tag_set" {
  command   = plan
  state_key = "tags_to_null"

  variables {
    tags = null
  }

  assert {
    condition     = length(azapi_resource_action.tags) == 0
    error_message = "Changing tags from a map to null removes the action without an Azure request; use an explicit empty map to clear tags."
  }
}

run "skip_service_principal_aad_check_preserves_principal_type_precedence" {
  command = plan

  variables {
    role_assignments = {
      default_service_principal_type = {
        role_definition_id_or_name       = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleDefinitions/00000000-0000-0000-0000-000000000001"
        principal_id                     = "00000000-0000-0000-0000-000000000002"
        skip_service_principal_aad_check = true
      }
      explicit_principal_type = {
        role_definition_id_or_name       = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleDefinitions/00000000-0000-0000-0000-000000000001"
        principal_id                     = "00000000-0000-0000-0000-000000000003"
        skip_service_principal_aad_check = true
        principal_type                   = "User"
      }
    }
  }

  assert {
    condition     = azapi_resource.role_assignment["default_service_principal_type"].body.properties.principalType == "ServicePrincipal"
    error_message = "When principal_type is omitted, skip_service_principal_aad_check must preserve AzureRM's ServicePrincipal request value."
  }

  assert {
    condition     = azapi_resource.role_assignment["explicit_principal_type"].body.properties.principalType == "User"
    error_message = "An explicit principal_type must take precedence over the compatibility behavior of skip_service_principal_aad_check."
  }
}

run "default_retry_includes_scope_locked_for_lock_removal_races" {
  command = plan

  variables {
    diagnostic_settings = {
      logs = {
        workspace_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.OperationalInsights/workspaces/log-test"
      }
    }
  }

  assert {
    condition     = contains(azapi_resource.diagnostic_setting["logs"].retry.error_message_regex, "ScopeLocked")
    error_message = "The default retry list must reach diagnostic settings and include ScopeLocked for transient deletion failures while locks are removed."
  }
}

# ---------------------------------------------------------------------------
# THE LOCK. `avm-utl-interfaces` returns a null name and no `notes`; both are
# restored here, because the lock's NAME is part of its resource ID and a
# `moved` block that lands on a different name is not a move.
# ---------------------------------------------------------------------------
run "lock_keeps_the_azurerm_generated_name_and_notes" {
  command = plan

  variables {
    lock = { kind = "CanNotDelete" }
  }

  assert {
    condition     = azapi_resource.lock[0].name == "lock-CanNotDelete"
    error_message = "With no lock name supplied the module must generate `lock-<kind>`, exactly as the AzureRM implementation did. avm-utl-interfaces returns null here, and the lock name is part of its resource ID -- taking the null would point the moved block at a different resource."
  }

  assert {
    condition     = azapi_resource.lock[0].body.properties.level == "CanNotDelete"
    error_message = "The lock level must be the configured kind."
  }

  assert {
    condition     = azapi_resource.lock[0].body.properties.notes == "Cannot delete the resource or its child resources."
    error_message = "AzureRM always set lock notes; avm-utl-interfaces leaves them null. Restoring the AzureRM string keeps the upgrade plan free of an avoidable lock body diff."
  }
}

run "read_only_lock_notes_match_azurerm" {
  command = plan

  variables {
    lock = { kind = "ReadOnly", name = "my-lock" }
  }

  assert {
    condition     = azapi_resource.lock[0].name == "my-lock"
    error_message = "A supplied lock name must win over the generated one."
  }

  assert {
    condition     = azapi_resource.lock[0].body.properties.notes == "Cannot delete or modify the resource or its child resources."
    error_message = "The ReadOnly lock note must match the AzureRM string exactly."
  }
}

# Variant 2 of the AVM lock interface (`avm_interface_lock_deprecated`) adds
# `notes`. A consumer value must win over the AzureRM fallback, otherwise the
# input is decorative.
run "a_supplied_lock_note_wins_over_the_azurerm_fallback" {
  command = plan

  variables {
    lock = { kind = "CanNotDelete", notes = "Owned by the network platform team." }
  }

  assert {
    condition     = azapi_resource.lock[0].body.properties.notes == "Owned by the network platform team."
    error_message = "A consumer-supplied lock note must win over the AzureRM default string."
  }
}

# ---------------------------------------------------------------------------
# DIAGNOSTIC SETTINGS. One deliberate deviation from `avm-utl-interfaces`.
# ---------------------------------------------------------------------------
run "dedicated_destination_type_is_sent_as_null" {
  command = plan

  variables {
    diagnostic_settings = {
      dedicated = {
        log_analytics_destination_type = "Dedicated"
        workspace_resource_id          = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.OperationalInsights/workspaces/law-test"
      }
      azure_diagnostics = {
        log_analytics_destination_type = "AzureDiagnostics"
        workspace_resource_id          = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.OperationalInsights/workspaces/law-test"
      }
    }
  }

  # 🔴 The AzureRM implementation sent NOTHING for `Dedicated`
  # (`log_analytics_destination_type == "Dedicated" ? null : ...`), while
  # avm-utl-interfaces always sends the literal. `ignore_null_property = true`
  # then prunes the null, so the request matches AzureRM's and the upgrade plan
  # shows no body diff on an existing diagnostic setting.
  assert {
    condition     = local.diagnostic_setting_bodies["dedicated"].properties.logAnalyticsDestinationType == null
    error_message = "A Dedicated destination type must be pruned to null, reproducing the AzureRM implementation. Sending the literal would put a body diff on every existing diagnostic setting the moment consumers upgrade."
  }

  assert {
    condition     = local.diagnostic_setting_bodies["azure_diagnostics"].properties.logAnalyticsDestinationType == "AzureDiagnostics"
    error_message = "AzureDiagnostics must still be sent verbatim."
  }

  assert {
    condition     = local.diagnostic_setting_names["dedicated"] == "diag-pip-unit-test"
    error_message = "An unnamed diagnostic setting must fall back to `diag-<public ip name>`, as the AzureRM implementation did. A different fallback renames every migrated diagnostic setting, and the name is part of the resource ID."
  }

  assert {
    condition     = local.diagnostic_setting_bodies["dedicated"].properties.workspaceId == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.OperationalInsights/workspaces/law-test"
    error_message = "The interfaces body must survive the logAnalyticsDestinationType override -- the override merges, it does not replace."
  }
}

# ---------------------------------------------------------------------------
# PARTIAL LIST MANAGEMENT on the diagnostic setting -- the fix for the
# perpetual `properties.logs` diff that was recorded as D-7.
#
# ⚠️ A MOCK CANNOT SEE THE BUG THIS GUARDS. The defect only appears against
# real ARM, whose GET returns the COMPLETE category-group set for the parent
# resource type (measured on `Microsoft.Network/publicIPAddresses`: the PUT
# echoes `allLogs` alone, the next GET adds `audit` disabled). This run is a
# REGRESSION GUARD on the two arguments only -- proof of convergence is the
# live step-6 re-plan, not this assertion.
# ---------------------------------------------------------------------------
run "diagnostic_setting_ignores_response_only_list_items" {
  command = plan

  variables {
    diagnostic_settings = {
      this = {
        workspace_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.OperationalInsights/workspaces/law-test"
      }
    }
  }

  assert {
    condition = (
      contains(azapi_resource.diagnostic_setting["this"].ignore_other_items_in_list, "properties.logs") &&
      contains(azapi_resource.diagnostic_setting["this"].ignore_other_items_in_list, "properties.metrics")
    )
    error_message = "Both list paths must be under partial-list management. ARM returns every category group and every metric category the parent type supports, including the ones this module never sent, and each unmanaged element is otherwise permanent plan drift."
  }

  # The composite key is load-bearing: a category-group entry carries
  # `category = null` and a log-category entry carries `categoryGroup = null`,
  # so neither field alone identifies an element. Matching on one of them
  # would collide every entry of the other kind onto a single null key.
  assert {
    condition     = azapi_resource.diagnostic_setting["this"].list_unique_id_property["properties.logs"] == "category, categoryGroup"
    error_message = "`properties.logs` must be matched on the composite `category, categoryGroup` key. Either field alone is null for half the entries and cannot identify a list element."
  }

  assert {
    condition     = azapi_resource.diagnostic_setting["this"].list_unique_id_property["properties.metrics"] == "category"
    error_message = "`properties.metrics` elements are identified by `category` alone -- there is no categoryGroup on a metric."
  }

  # The fix must NOT be `ignore_changes = [body]` in disguise. `body` stays
  # under Terraform's control so a consumer-driven log/metric change still
  # plans and applies; only response-only elements are ignored.
  assert {
    condition     = azapi_resource.diagnostic_setting["this"].body != null
    error_message = "`body` must remain live configuration. Suppressing the drift by ignoring the whole body would also kill every day-2 diagnostic-setting update."
  }
}

# ---------------------------------------------------------------------------
# TIMEOUTS. The migration must be timeout-neutral by default.
# ---------------------------------------------------------------------------
run "timeouts_default_to_the_azurerm_values" {
  command = plan

  assert {
    condition = (
      local.timeouts.network_public_ip_addresses.create == "30m" &&
      local.timeouts.network_public_ip_addresses.read == "5m" &&
      local.timeouts.network_public_ip_addresses.update == "30m" &&
      local.timeouts.network_public_ip_addresses.delete == "30m"
    )
    error_message = "The public IP address timeouts must default to AzureRM's own (public_ip_resource.go L50-L53), or the migration silently changes failure behaviour."
  }

  assert {
    condition     = local.timeouts.insights_diagnostic_settings.delete == "60m"
    error_message = "Diagnostic settings had a 60m delete timeout in AzureRM, not 30m."
  }
}

run "a_consumer_timeout_override_applies_everywhere" {
  command = plan

  variables {
    timeouts = { create = "45m" }
  }

  assert {
    condition = (
      local.timeouts.network_public_ip_addresses.create == "45m" &&
      local.timeouts.authorization_locks.create == "45m" &&
      local.timeouts.insights_diagnostic_settings.create == "45m" &&
      local.timeouts.insights_diagnostic_settings.delete == "60m"
    )
    error_message = "An override must replace only the member supplied; the others must keep their per-resource AzureRM default."
  }
}

# TFFR7 / `avm_interface_timeouts`: the variable must PERMIT `null`, so the
# null input has to reach the same place every-member-null does.
run "a_null_timeouts_object_falls_back_to_the_azurerm_defaults" {
  command = plan

  variables {
    timeouts = null
  }

  assert {
    condition = (
      local.timeouts.network_public_ip_addresses.create == "30m" &&
      local.timeouts.network_public_ip_addresses.read == "5m" &&
      local.timeouts.authorization_role_assignments.update == "30m" &&
      local.timeouts.insights_diagnostic_settings.delete == "60m"
    )
    error_message = "`timeouts = null` must behave exactly like every member being null. The variable cannot be fenced off with `nullable = false` -- avm_interface_timeouts forbids it."
  }
}

# ---------------------------------------------------------------------------
# API VERSIONS. The defaults are pinned to the newest versions embedded in the
# azapi provider this module resolves, because `MoveResourceState` picks
# `candidateApiVersions[len-1]` -- so matching it is what keeps `type` drift
# off the upgrade plan for the resources that do NOT ignore `type`.
# ---------------------------------------------------------------------------
run "resource_types_reach_the_resources_they_name" {
  command = plan
  # Isolated state: with no prior state, nothing is pinned by
  # `ignore_changes`, so this run sees what a GREENFIELD consumer gets.
  state_key = "resource_types_greenfield"

  variables {
    lock = { kind = "CanNotDelete" }
    tags = { scenario = "unit" }
    diagnostic_settings = {
      this = {
        workspace_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.OperationalInsights/workspaces/law-test"
      }
    }
    resource_types = {
      network_public_ip_addresses = "Microsoft.Network/publicIPAddresses@2024-05-01"
    }
  }

  assert {
    condition     = azapi_resource.this.type == "Microsoft.Network/publicIPAddresses@2024-05-01" && azapi_update_resource.this.type == "Microsoft.Network/publicIPAddresses@2024-05-01"
    error_message = "An overridden API version must reach BOTH writers for the same resource, or the create and day-2 paths disagree on the contract."
  }

  assert {
    condition = (
      azapi_resource.lock[0].type == "Microsoft.Authorization/locks@2020-05-01" &&
      azapi_resource.diagnostic_setting["this"].type == "Microsoft.Insights/diagnosticSettings@2021-05-01-preview" &&
      azapi_resource_action.tags[0].type == "Microsoft.Resources/tags@2021-04-01"
    )
    error_message = "The satellite resources must keep their own defaults when only the public IP type is overridden. These three do NOT ignore `type`, so their defaults are what keep the moved upgrade plan free of type drift."
  }
}

# ⭐ THE PROPERTY THAT MAKES THE `moved` UPGRADE PLAN SAFE.
#
# `azapi`'s `MoveResourceState` does not read this module's configuration: it
# picks `candidateApiVersions[len-1]` after a lexicographic sort and writes
# THAT into the migrated state. If `type` were a live attribute on the
# create-only writer, any mismatch between that choice and
# `var.resource_types` would put a `type` change on the upgrade plan.
#
# `type` is in the create-only writer's `ignore_changes`, so the migrated value
# wins and the public IP address is immune to the choice. The two runs below
# pin that: once a public IP is in state, a changed API version is INVISIBLE on
# the full writer and VISIBLE on the merge writer.
#
# 🔴 The flip side, and the reason `var.resource_types` still matters: the
# lock, the role assignments and the diagnostic settings do NOT ignore `type`,
# so their defaults must match what the provider will pick.
run "seed_state_for_the_type_pinning_check" {
  command   = apply
  state_key = "type_pinning"

  assert {
    condition     = azapi_resource.this.type == "Microsoft.Network/publicIPAddresses@2025-07-01"
    error_message = "The seeded state must carry the module's default API version, or the run below proves nothing."
  }
}

run "type_drift_is_invisible_on_the_create_only_writer" {
  command   = plan
  state_key = "type_pinning"

  variables {
    resource_types = {
      network_public_ip_addresses = "Microsoft.Network/publicIPAddresses@2024-05-01"
    }
  }

  assert {
    condition     = azapi_resource.this.type == "Microsoft.Network/publicIPAddresses@2025-07-01"
    error_message = "lifecycle.ignore_changes must contain `type` on the create-only writer: once a public IP address is in state, its API version must stay pinned to the state value. This is what makes the moved upgrade plan immune to the version azapi's MoveResourceState picks -- and it also means changing var.resource_types.network_public_ip_addresses is a NO-OP on an existing resource."
  }

  assert {
    condition     = azapi_update_resource.this.type == "Microsoft.Network/publicIPAddresses@2024-05-01"
    error_message = "The merge writer must follow the configuration. If it did not, this test would not be discriminating and the assertion above would prove nothing."
  }
}
