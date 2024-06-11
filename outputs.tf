output "public_ip_address" {
  description = "The assigned IP address of the public IP"
  value       = azurerm_public_ip.this.ip_address
}

output "public_ip_id" {
  description = "The ID of the created public IP address"
  value       = azurerm_public_ip.this.id
}

# Module owners should include the full resource via a 'resource' output
# https://azure.github.io/Azure-Verified-Modules/specs/terraform/#id-tffr2---category-outputs---additional-terraform-outputs
output "resource" {
  description = "This is the full output for the resource."
  value       = azurerm_public_ip.this
}

output "resource_id" {
  description = "This is the resource ID of the created public IP"
  value       = azurerm_public_ip.this.id
}
