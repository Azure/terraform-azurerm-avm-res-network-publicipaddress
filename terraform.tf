terraform {
  # `~> 1.9`, raised from `>= 1.0.0`: `var.parent_id` is validated with the
  # provider-defined function `provider::azapi::parse_resource_id` (TFNFR38),
  # which needs Terraform 1.8 or later. It is not raised to 1.11 for
  # `ignore_body_changes`: the `[]` -> `null` collapse keeps that argument absent
  # at its default, so a consumer on 1.9 is unaffected until they set it.
  required_version = "~> 1.9"

  required_providers {
    azapi = {
      source = "Azure/azapi"
      # TFFR3. The 2.12 floor is required for `ignore_body_changes`. 2.13.0 is
      # what resolves today, and the API-version defaults in
      # `var.resource_types` are aligned to it.
      version = "~> 2.12"
    }
  }
}
