mock_provider "azapi" {
  mock_data "azapi_client_config" {
    defaults = {
      subscription_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000"
    }
  }
}

mock_provider "random" {
  mock_resource "random_uuid" {
    defaults = {
      result = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    }
  }
}

override_resource {
  target = azapi_resource.this
  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/publicIPAddresses/pip-review"
  }
}

override_data {
  target = data.azapi_resource.this
  values = {
    output = { properties = { ipAddress = "192.0.2.1" } }
  }
}

override_data {
  target = module.interfaces.data.azapi_resource_list.role_definitions[0]
  values = {
    output = {
      results = [{
        id        = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7"
        role_name = "Reader"
      }]
    }
  }
}

variables {
  enable_telemetry = false
  name             = "pip-review"
  location         = "eastus"
  parent_id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test"
  role_assignments = {
    reader = {
      name                       = "11111111-1111-4111-8111-111111111111"
      principal_id               = "22222222-2222-4222-8222-222222222222"
      role_definition_id_or_name = "Reader"
    }
  }
}

run "seed_existing_assignment" {
  command = apply
  assert {
    condition     = azapi_resource.role_assignment["reader"].body.properties.roleDefinitionId == "/subscriptions/00000000-0000-0000-0000-000000000000/providers/microsoft.authorization/roledefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7"
    error_message = "The utility must resolve the role name to its resource ID, sent in lowercase."
  }
  providers = {
    azapi  = azapi
    random = random
  }
}

run "role_assignment_name_is_derived_when_not_pinned" {
  command = plan
  variables {
    role_assignments = {
      fresh = {
        principal_id               = "22222222-2222-4222-8222-222222222222"
        role_definition_id_or_name = "Reader"
      }
    }
  }
  assert {
    condition = azapi_resource.role_assignment["fresh"].name == uuidv5("url", join("|", [
      lower(azapi_resource.this.id),
      "22222222-2222-4222-8222-222222222222",
      "/subscriptions/00000000-0000-0000-0000-000000000000/providers/microsoft.authorization/roledefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7",
      "-",
    ]))
    error_message = "An unpinned role assignment must take a name derived from its scope, principal, role and delegated identity."
  }
  providers = {
    azapi  = azapi
    random = random
  }
}

run "default_retry_reaches_merge_writer" {
  command = plan
  assert {
    condition     = azapi_update_resource.this.retry != null ? contains(azapi_update_resource.this.retry.error_message_regex, "AnotherOperationInProgress") : false
    error_message = "The day-two writer must receive the default transient-operation retry settings."
  }
  providers = {
    azapi  = azapi
    random = random
  }
}

run "custom_retry_reaches_merge_writer" {
  command = plan
  variables {
    retry = {
      error_message_regex  = ["ReviewRetryable"]
      interval_seconds     = 3
      max_interval_seconds = 15
    }
  }
  assert {
    condition = azapi_update_resource.this.retry != null ? (
      azapi_update_resource.this.retry.error_message_regex == tolist(["ReviewRetryable"]) &&
      azapi_update_resource.this.retry.interval_seconds == 3 &&
      azapi_update_resource.this.retry.max_interval_seconds == 15
    ) : false
    error_message = "Consumer retry overrides must reach the day-two writer."
  }
  providers = {
    azapi  = azapi
    random = random
  }
}
