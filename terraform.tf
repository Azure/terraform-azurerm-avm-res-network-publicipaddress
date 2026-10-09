terraform {
  # `~> 1.9` and not the previous `>= 1.0.0`. The floor is raised because
  # `var.parent_id` is validated with the PROVIDER-DEFINED function
  # `provider::azapi::parse_resource_id` (TFNFR38), and provider-defined
  # functions do not exist before Terraform 1.8. 1.9 is the floor used by the
  # sibling AVM AzAPI modules (`avm-res-network-natgateway` v0.3.2,
  # `avm-utl-interfaces` v0.6.0), so this module does not introduce a new one.
  #
  # NOTE: it is NOT raised to 1.11 for `ignore_body_changes`. The
  # `avm-tf-azapi` SKILL is explicit -- "do not raise the Terraform version
  # floor solely for this feature" -- and the `[]` -> `null` collapse below
  # keeps the write-only argument ABSENT at its default, so a consumer on 1.9
  # is unaffected until they actually populate it.
  required_version = "~> 1.9"

  required_providers {
    azapi = {
      source = "Azure/azapi"
      # TFFR3. `~> 2.12` means `>= 2.12, < 3.0`; the 2.12 floor is required for
      # `ignore_body_changes`. The provider that currently resolves in this
      # repository is 2.13.0, which is what the API-version defaults in
      # `var.resource_types` are aligned to -- see the note there.
      version = "~> 2.12"
    }
    modtm = {
      source  = "azure/modtm"
      version = "~> 0.3"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5.0"
    }
  }
}
