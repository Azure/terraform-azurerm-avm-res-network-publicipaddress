# ---------------------------------------------------------------------------
# Output names, descriptions and meanings are unchanged from the AzureRM
# implementation, so a consumer keeps every `module.<x>.<output>` reference.
# ---------------------------------------------------------------------------


output "name" {
  description = "The name of the created public IP address"
  value       = azapi_resource.this.name
}

output "public_ip_address" {
  description = "The assigned IP address of the public IP"
  # Read from the data source, not a writer (see `main.tf`). It depends only on
  # `azapi_resource.this.id`, so the output stays known on the `moved` upgrade
  # plan. `try(..., null)` because `properties.ipAddress` is absent until ARM
  # allocates one (a `Dynamic` IP has none until attached). AzureRM returned
  # `""` there; this returns `null`.
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
