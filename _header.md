# terraform-azurerm-avm-res-network-publicipaddress

This is a module developed as part of Terraform Azure Verified Modules project and can be used to deploy Public IP Address.

## Upgrading from v0.2.1 and earlier

This release migrates the module from the `azurerm` provider to `azapi`. The in-module `moved`
blocks map existing AzureRM state for the public IP, lock, role assignments and diagnostic settings
to their AzAPI resources. Review the plan for unexpected destroys or replacements before applying.

What you need to know:

- **`parent_id` replaces `resource_group_name`.** Pass the resource ID of the existing resource
  group, for example `/subscriptions/<subscription-id>/resourceGroups/<name>`. This is a breaking
  change to the module inputs.
- **Plan with refresh enabled.** Use Terraform's default refresh when planning the upgrade. Review
  the plan and stop if it shows an unexpected replacement of an existing resource.
- **Keep an `azurerm` provider block in the root module for the upgrade apply.** Terraform must be
  able to read the pre-migration state rows before the `moved` blocks convert them. The block can be
  removed afterwards.
- **Outputs keep their names.** `public_ip_address` is `null` instead of `""` while a `Dynamic`
  public IP has no address allocated.
- **Tag handling differs for `null` and `{}`.** `tags = null` disables the tag action and does not
  clear tags. Set `tags = {}` to explicitly clear the complete tag set. When the action runs, it
  replaces all tags with the configured map; it does not read or track out-of-band tag changes, and
  an unrelated apply does not necessarily run it.
- **DNS settings cannot be removed or switched in place.** The day-2 writer merges nested settings
  and cannot remove an omitted `domain_name_label` or `reverse_fqdn`. The module rejects removing
  either configured member or switching from one to the other on an existing public IP.
- **Role-assignment principal type is preserved.** When
  `skip_service_principal_aad_check = true` and `principal_type` is unset, the module sends
  `principalType = "ServicePrincipal"` as the AzureRM implementation did. An explicitly configured
  `principal_type` takes precedence.
- **Existing role-assignment GUIDs are retained.** Changes to the principal, resolved role
  definition, or delegated managed identity replace the assignment with a new GUID. See
  [Changing an existing role assignment](#changing-an-existing-role-assignment).
- **Remove blocking locks before upgrading.** New locks are created after the public IP merge
  writer and tag action, but this ordering cannot unlock existing resources. See
  [Migrating a locked public IP](#migrating-a-locked-public-ip).
- **Lock-removal retries are targeted, not a teardown guarantee.** The default retry list includes
  `ScopeLocked` for transient diagnostic-settings deletion failures while a lock is being removed.
- **Use only the in-module state moves.** Use a normally refreshed plan and stop if it shows an
  unexpected replacement.
- **Minimum Terraform is now 1.9.** `parent_id` is validated with a provider-defined function.
- **New optional inputs.** `resource_types`, `ignore_body_changes`, `retry` and `timeouts`. Their
  defaults preserve the previous behaviour.

### Migrating a locked public IP

An existing `ReadOnly` lock blocks the merge PUT and tag action during migration, even if the
public IP settings are unchanged. Dependency ordering only protects creation of a new lock;
it does not remove or bypass a lock already in Azure. Retries cannot fix a persistent lock.

1. Before upgrading, remove the module-managed lock in a separate apply using the currently
   deployed module version (`lock = null`). Have the owner remove any inherited `ReadOnly`
   locks at the resource-group or subscription scope separately; this module cannot remove
   those locks.
2. Keep `lock = null` while upgrading. Review a normally refreshed plan, apply the migration,
   and verify convergence before restoring protection.
3. Restore the desired module lock in a separate apply, then have the relevant owners restore
   inherited locks. For future configuration writes under a `ReadOnly` lock, use the same
   unlock/change/relock sequence.

Do not merely remove a lock from Terraform state: that leaves the Azure lock in place.
Coordinate the temporary loss of protection with the resource and inherited-lock owners.

### Changing an existing role assignment

The module keeps the GUID of an adopted role assignment while its principal, resolved
role-definition ID and delegated managed identity stay the same. Description and condition
changes update the assignment in place and keep the GUID. A change to the principal, the
resolved role or the delegated identity cannot be updated in place in Azure, so the module
replaces the assignment, and the replacement gets a new GUID derived from those values. A
`name` you set yourself is used for the replacement instead, so set a new name when you replace
an assignment with a changed principal. A change to `name` alone does not rename an existing
assignment.

To change an immutable value:

1. Coordinate with the resource owner and remove blocking locks in a separate apply. A
   `CanNotDelete` lock also blocks role-assignment removal; check resource-level and inherited
   resource-group/subscription locks. Use an identity that will retain permission to complete
   the change after the old assignment is removed.
2. Change the value in `role_assignments` and review the plan. It must show the assignment
   replaced, with a new name, and not updated in place. The old assignment is deleted first, so
   its access is interrupted until the new one exists.
3. Apply, verify the resulting access, and restore module-managed and inherited locks
   separately.

Plan the first apply after upgrading from the AzureRM module with no role-assignment changes.
That plan shows each assignment updated in place once, with an unchanged body, while the
replacement settings are stored. Use a normally refreshed plan, and stop if it shows a role
assignment replaced.
