# Input validation, pinned. Every `validation` block this migration added or
# changed gets a case here, because the module's public API is the one thing a
# provider migration is not allowed to break by accident.
#
# All runs are `command = plan` with mocked providers: a variable validation
# failure is raised during variable evaluation, before any provider is
# configured and long before any request would be made, so these runs never
# reach Azure.

mock_provider "azapi" {}
mock_provider "modtm" {}
mock_provider "random" {}

variables {
  enable_telemetry = false
  location         = "eastus"
  name             = "pip-unit-test"
  parent_id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test"
}

# ---------------------------------------------------------------------------
# `parent_id` -- REQUIRED, and the only way to name the parent scope.
#
# Maintainer ruling 2026-09-30 (D-1): strict `avm-tf-azapi` SKILL L167-182 /
# TFRMFR1. `resource_group_name` is gone and the module never constructs a
# parent ID, so there is no longer an exactly-one-of pair to police -- only
# that the input is present, parseable, and used verbatim. This is a MAJOR
# version bump; these runs are what keep the new contract true.
# ---------------------------------------------------------------------------
run "parent_id_is_required" {
  command = plan

  variables {
    parent_id = null
  }

  expect_failures = [var.parent_id]
}

run "parent_id_is_used_verbatim" {
  command = plan

  variables {
    parent_id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-verbatim"
  }

  # The module must not rewrite, re-case or re-derive the caller's scope, and
  # must not consult a provider for a subscription -- there is no
  # `data.azapi_client_config` on the functional path any more.
  assert {
    condition     = local.parent_id == "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-verbatim"
    error_message = "`local.parent_id` must be exactly the caller-supplied `var.parent_id`."
  }

  assert {
    condition     = local.parent_subscription_id == "/subscriptions/11111111-1111-1111-1111-111111111111"
    error_message = "The subscription scope used for role-definition lookup must come from `var.parent_id`, not from a provider."
  }
}

# ---------------------------------------------------------------------------
# TFNFR38 -- resource IDs are parsed, not regex-guessed.
# ---------------------------------------------------------------------------
run "parent_id_must_be_a_resource_group_id" {
  command = plan

  variables {
    # A virtual network, not a resource group. Syntactically a valid ARM ID,
    # so only a real parse rejects it.
    parent_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-test"
  }

  expect_failures = [var.parent_id]
}

run "ddos_protection_plan_id_must_be_a_ddos_protection_plan_id" {
  command = plan

  variables {
    ddos_protection_plan_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-test"
  }

  expect_failures = [var.ddos_protection_plan_id]
}

run "public_ip_prefix_id_must_be_a_public_ip_prefix_id" {
  command = plan

  variables {
    public_ip_prefix_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/publicIPAddresses/pip-test"
  }

  expect_failures = [var.public_ip_prefix_id]
}

# Both ID validations must tolerate their documented `null` default, or every
# consumer who does not use DDoS or prefixes is broken by the upgrade.
run "null_is_still_valid_for_the_optional_resource_ids" {
  command = plan

  variables {
    ddos_protection_plan_id = null
    public_ip_prefix_id     = null
  }

  assert {
    condition     = local.pip_config_ddos_plan_id == null && local.pip_config_prefix_id == null
    error_message = "An unset ddos_protection_plan_id / public_ip_prefix_id must leave the body member absent, not present-and-null."
  }
}

# ---------------------------------------------------------------------------
# `role_assignments[*].name` -- added by this migration so a consumer can pin a
# name. `avm-utl-interfaces` rejects a non-GUID too; validating here as well
# puts the error on the input the consumer actually wrote.
# ---------------------------------------------------------------------------
run "role_assignment_name_must_be_a_lowercase_guid" {
  command = plan

  variables {
    role_assignments = {
      bad = {
        name                       = "NOT-A-GUID"
        role_definition_id_or_name = "Reader"
        principal_id               = "00000000-0000-0000-0000-000000000001"
      }
    }
  }

  expect_failures = [var.role_assignments]
}

# ---------------------------------------------------------------------------
# `ignore_body_changes` -- an empty-string path is silently useless, so it is
# refused.
# ---------------------------------------------------------------------------
run "ignore_body_changes_rejects_an_empty_path" {
  command = plan

  variables {
    ignore_body_changes = {
      network_public_ip_addresses = ["properties.sku.name", "  "]
    }
  }

  expect_failures = [var.ignore_body_changes]
}
