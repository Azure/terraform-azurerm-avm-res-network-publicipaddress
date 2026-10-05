# ---------------------------------------------------------------------------
# The output NAMES, DESCRIPTIONS and MEANINGS are unchanged from the AzureRM
# implementation. This is a provider migration IN PLACE, so a consumer bumps
# the module version and keeps every `module.<x>.<output>` reference it already
# has.
# ---------------------------------------------------------------------------


output "name" {
  description = "The name of the created public IP address"
  value       = azapi_resource.this.name
}

output "public_ip_address" {
  description = "The assigned IP address of the public IP"
  # Read from the READ-ONLY data source, never from a writer -- see the
  # `response_export_values` note on `azapi_resource.this` in `main.tf`. The
  # data source depends only on `azapi_resource.this.id`, which is already in
  # state on the `moved` upgrade plan, so this output stays KNOWN through the
  # migration instead of becoming "(known after apply)" and cascading unknowns
  # into every consumer.
  #
  # `try(..., null)` because `properties.ipAddress` is ABSENT, not empty,
  # until ARM has allocated one: a `Dynamic` public IP has no address until it
  # is attached to something. AzureRM surfaced that as `""`; this surfaces it
  # as `null`. A `Static` public IP -- this module's default -- always has one.
  value = try(data.azapi_resource.this.output.properties.ipAddress, null)
}

output "public_ip_id" {
  description = "The ID of the created public IP address"
  value       = azapi_resource.this.id
}

output "resource_id" {
  description = "The ID of the created public IP address"
  value       = azapi_resource.this.id
}
