# TODO: insert outputs here.

output "public_ip_id" {
  description = "The ID of the created public IP address"
  value       = azurerm_public_ip.this
}

output "public_ip_address" {
  description = "The assigned IP address of the public IP"
  value       = azurerm_public_ip.this.ip_address
}