output "assigned_ip_address" {
  description = "The IP address allocated to the public IP address resource."
  value       = module.public_ip_address.public_ip_address
}

output "created_resource" {
  description = "The resource ID of the public IP address resource."
  value       = module.public_ip_address.public_ip_id
}
