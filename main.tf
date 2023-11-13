# TODO: insert resources here.


resource "azurerm_public_ip" "this"{
    name = var.name
    resource_group_name = var.resource_group_name
    location = var.location
    allocation_method = var.allocation_method
    sku = var.sku
    zones = var.zones
    ip_version = var.ip_version
    domain_name_label = var.domain_name_label
    reverse_fqdn = var.reverse_fqdn
    tags = var.tags
    public_ip_address_version = var.public_ip_address_version
    public_ip_prefix_id = var.public_ip_prefix_id
    public_ip_address_allocation = var.public_ip_address_allocation
    idle_timeout_in_minutes = var.idle_timeout_in_minutes
    ip_configuration_id = var.ip_configuration_id
    ip_tags = var.ip_tags
    ip_configuration_name = var.ip_configuration_name
    sku_tier = var.sku_tier
    reverse_fqdn_fqdn = var.reverse_fqdn_fqdn
}
resource "azurerm_management_lock" "this" {
  count      = var.lock.kind != "None" ? 1 : 0
  name       = coalesce(var.lock.name, "lock-${var.name}")
  scope      = azurerm_network_ddos_protection_plan.this.id
  lock_level = var.lock.kind
}

resource "azurerm_role_assignment" "this" {
  for_each                               = var.role_assignments
  scope                                  = azurerm_network_ddos_protection_plan.this.id
  role_definition_id                     = strcontains(lower(each.value.role_definition_id_or_name), lower(local.role_definition_resource_substring)) ? each.value.role_definition_id_or_name : null
  role_definition_name                   = strcontains(lower(each.value.role_definition_id_or_name), lower(local.role_definition_resource_substring)) ? null : each.value.role_definition_id_or_name
  principal_id                           = each.value.principal_id
  condition                              = each.value.condition
  condition_version                      = each.value.condition_version
  skip_service_principal_aad_check       = each.value.skip_service_principal_aad_check
  delegated_managed_identity_resource_id = each.value.delegated_managed_identity_resource_id
}

resource "azurerm_monitor_diagnostic_setting" "this" {
  for_each                       = var.diagnostic_settings
  name                           = each.value.name != null ? each.value.name : "diag-${var.name}"
  target_resource_id             = azurerm_network_ddos_protection_plan.this.id
  storage_account_id             = each.value.storage_account_resource_id
  eventhub_authorization_rule_id = each.value.event_hub_authorization_rule_resource_id
  eventhub_name                  = each.value.event_hub_name
  partner_solution_id            = each.value.marketplace_partner_resource_id
  log_analytics_workspace_id     = each.value.workspace_resource_id
  log_analytics_destination_type = each.value.log_analytics_destination_type

  dynamic "enabled_log" {
    for_each = each.value.log_categories
    content {
      category = enabled_log.value
    }
  }

  dynamic "enabled_log" {
    for_each = each.value.log_groups
    content {
      category_group = enabled_log.value
    }
  }
  
  dynamic "metric" {
    for_each = each.value.metric_categories
    content {
      category = metric.value
    }
  }
}