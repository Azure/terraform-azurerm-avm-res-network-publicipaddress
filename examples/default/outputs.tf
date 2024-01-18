output "created_resource" {
  value = module.PublicIPAddress.public_ip_id
}
output "assigned_ip_address" {
  value = module.PublicIPAddress.public_ip_address
}

