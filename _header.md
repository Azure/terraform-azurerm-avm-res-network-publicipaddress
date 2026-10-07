# terraform-azurerm-avm-res-network-publicipaddress

This is a module developed as part of Terraform Azure Verified Modules project and can be used to deploy Public IP Address.

## Upgrading from v0.2.1 and earlier

This release migrates the module from the `azurerm` provider to `azapi`. The in-module `moved`
blocks convert the existing state rows for the public IP, lock, role assignments and diagnostic
settings in place, with no destroy and no replacement.

What you need to know:

- **`parent_id` replaces `resource_group_name`.** Pass the resource ID of the existing resource
  group, for example `/subscriptions/<subscription-id>/resourceGroups/<name>`. This is a breaking
  change to the module inputs.
- **Plan with a normal refresh.** `terraform plan -refresh=false`, and any sovereign cloud, hit
  [azapi#1227](https://github.com/Azure/terraform-provider-azapi/issues/1227) and plan a *replace*
  instead of a move.
- **Keep an `azurerm` provider block in the root module for the upgrade apply.** Terraform must be
  able to read the pre-migration state rows before the `moved` blocks convert them. The block can be
  removed afterwards.
- **Outputs keep their names.** `public_ip_address` is `null` instead of `""` while a `Dynamic`
  public IP has no address allocated.
- **Tags replace the whole tag set.** Tags placed on the public IP out of band are removed on the
  next apply.
- **Minimum Terraform is now 1.9.** `parent_id` is validated with a provider-defined function.
- **New optional inputs.** `resource_types`, `ignore_body_changes`, `retry` and `timeouts`. Their
  defaults preserve the previous behaviour.
