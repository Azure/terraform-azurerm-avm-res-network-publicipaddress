output "resource" {
  description = "This is the full output for the resource."
  value       = module.public_ip_address.resource
}

output "resource_id" {
  description = "This is the resource ID of the created public IP"
  value       = module.public_ip_address.resource_id
}
