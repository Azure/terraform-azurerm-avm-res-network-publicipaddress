# ⭐ THE FORCENEW GUARDS. AzureRM would have REPLACED the public IP address for
# any of these changes -- releasing the allocated IP. AzAPI cannot replace on a
# body property, so the module fails the plan instead of silently no-op'ing.
#
# WHY `command = apply` AND A SHARED `state_key`: the guards compare the STATE
# body against the CONFIGURED body. With no prior state there is nothing to
# compare, so each case needs a seeded state first and a second run on top of
# it. `mock_provider` keeps all of it off Azure.

mock_provider "azapi" {
  # 🔴 LOAD-BEARING. The azapi provider's SCHEMA-LEVEL validation runs even
  # under a mock, and `azapi_update_resource.resource_id` rejects an ID that
  # does not start with `/`. A generated mock ID is a bare random string.
  mock_resource "azapi_resource" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/publicIPAddresses/pip-unit-test"
    }
  }
  mock_data "azapi_client_config" {
    defaults = {
      subscription_id = "00000000-0000-0000-0000-000000000000"
      tenant_id       = "11111111-1111-1111-1111-111111111111"
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
# 1. Seed a live-looking public IP address: Standard / Regional / zonal.
# ---------------------------------------------------------------------------
run "seed_a_standard_zonal_public_ip" {
  command   = apply
  state_key = "forcenew"

  variables {
    sku      = "Standard"
    sku_tier = "Regional"
    zones    = [1, 2, 3]
  }

  assert {
    condition     = local.pip_state_sku_name == "standard" && local.pip_state_sku_tier == "regional"
    error_message = "The seeded state must carry the SKU in its body, or every guard below is comparing against nothing and proves nothing."
  }

  assert {
    condition     = local.pip_state_zones == toset(["1", "2", "3"])
    error_message = "The seeded state must carry the zones in its body."
  }
}

# ---------------------------------------------------------------------------
# 2. The positive control. A NON-ForceNew change must plan cleanly, or the
#    guards are simply refusing everything and the tests below prove nothing.
# ---------------------------------------------------------------------------
run "a_non_forcenew_change_still_plans" {
  command   = plan
  state_key = "forcenew"

  variables {
    sku                     = "Standard"
    sku_tier                = "Regional"
    zones                   = [1, 2, 3]
    idle_timeout_in_minutes = 15
    ddos_protection_mode    = "Enabled"
  }

  assert {
    condition     = local.public_ip_update_body.properties.idleTimeoutInMinutes == 15 && local.public_ip_update_body.properties.ddosSettings.protectionMode == "Enabled"
    error_message = "idle_timeout_in_minutes and ddos_protection_mode are day-2 assignable in AzureRM and must remain assignable through the merge writer."
  }
}

# ---------------------------------------------------------------------------
# 3. The guards themselves.
# ---------------------------------------------------------------------------
run "sku_change_is_refused" {
  command   = plan
  state_key = "forcenew"

  variables {
    sku      = "Basic"
    sku_tier = "Regional"
    zones    = [1, 2, 3]
  }

  expect_failures = [azapi_update_resource.this]
}

run "sku_tier_change_is_refused" {
  command   = plan
  state_key = "forcenew"

  variables {
    sku      = "Standard"
    sku_tier = "Global"
    zones    = [1, 2, 3]
  }

  expect_failures = [azapi_update_resource.this]
}

run "zones_change_is_refused" {
  command   = plan
  state_key = "forcenew"

  variables {
    sku      = "Standard"
    sku_tier = "Regional"
    zones    = [1, 2]
  }

  expect_failures = [azapi_update_resource.this]
}

run "ip_version_change_is_refused" {
  command   = plan
  state_key = "forcenew"

  variables {
    sku        = "Standard"
    sku_tier   = "Regional"
    zones      = [1, 2, 3]
    ip_version = "IPv6"
  }

  expect_failures = [azapi_update_resource.this]
}

run "edge_zone_change_is_refused" {
  command   = plan
  state_key = "forcenew"

  variables {
    sku       = "Standard"
    sku_tier  = "Regional"
    zones     = [1, 2, 3]
    edge_zone = "microsoftlosangeles1"
  }

  expect_failures = [azapi_update_resource.this]
}

run "ip_tags_change_is_refused" {
  command   = plan
  state_key = "forcenew"

  variables {
    sku      = "Standard"
    sku_tier = "Regional"
    zones    = [1, 2, 3]
    ip_tags  = { RoutingPreference = "Internet" }
  }

  expect_failures = [azapi_update_resource.this]
}

run "public_ip_prefix_id_change_is_refused" {
  command   = plan
  state_key = "forcenew"

  variables {
    sku                 = "Standard"
    sku_tier            = "Regional"
    zones               = [1, 2, 3]
    public_ip_prefix_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/publicIPPrefixes/prefix-test"
  }

  expect_failures = [azapi_update_resource.this]
}

run "ddos_protection_plan_id_change_is_refused" {
  command   = plan
  state_key = "forcenew"

  variables {
    sku                     = "Standard"
    sku_tier                = "Regional"
    zones                   = [1, 2, 3]
    ddos_protection_plan_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/ddosProtectionPlans/ddos-test"
  }

  expect_failures = [azapi_update_resource.this]
}

# ---------------------------------------------------------------------------
# 4. The merge-writer limitation guard. Not a ForceNew property -- a property
#    the day-2 writer physically cannot un-set, because a merge preserves
#    undeclared members of the live object.
# ---------------------------------------------------------------------------
run "seed_a_public_ip_with_dns_settings" {
  command   = apply
  state_key = "dnssettings"

  variables {
    domain_name_label = "pip-unit-test"
  }

  assert {
    condition     = local.pip_state_dns_label == "pip-unit-test"
    error_message = "The seeded state must carry the expected domain name label, or the removal guard is comparing against nothing."
  }
}

run "changing_the_domain_name_label_is_allowed" {
  command   = plan
  state_key = "dnssettings"

  variables {
    domain_name_label = "pip-unit-test-renamed"
  }

  assert {
    condition     = local.public_ip_update_body.properties.dnsSettings.domainNameLabel == "pip-unit-test-renamed"
    error_message = "CHANGING a domain name label is a normal day-2 update in AzureRM and must still work -- only REMOVAL is refused."
  }
}

run "switching_from_a_domain_label_to_reverse_fqdn_is_refused" {
  command   = plan
  state_key = "dnssettings"

  variables {
    domain_name_label = null
    reverse_fqdn      = "example.contoso.com."
  }

  # AzureRM replaces the DNS settings object when either field changes.
  # azapi_update_resource manages a subset and cannot remove the omitted
  # nested field, so the switch must not silently leave both fields configured.
  expect_failures = [azapi_update_resource.this]
}

run "seed_a_public_ip_with_reverse_fqdn" {
  command   = apply
  state_key = "dnssettings_reverse"

  variables {
    reverse_fqdn = "example.contoso.com."
  }
}

run "switching_from_reverse_fqdn_to_a_domain_label_is_refused" {
  command   = plan
  state_key = "dnssettings_reverse"

  variables {
    reverse_fqdn      = null
    domain_name_label = "pip-unit-test"
  }

  expect_failures = [azapi_update_resource.this]
}

run "removing_the_dns_settings_is_refused" {
  command   = plan
  state_key = "dnssettings"

  variables {
    domain_name_label = null
    reverse_fqdn      = null
  }

  # 🔴 AzureRM set `payload.Properties.DnsSettings = nil` here and ARM removed
  # the DNS settings. A merge writer cannot express that, so the removal would
  # be a SILENT no-op behind a plan that looked like it worked. Failing loudly
  # is the only honest option short of replacing the resource.
  expect_failures = [azapi_update_resource.this]
}
