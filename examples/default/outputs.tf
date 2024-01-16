output "Created_resource" {
    value = module.PublicIPAddress.public_ip_id
}
output "Assigned_IP_Address" {
    value = module.PublicIPAddress.public_ip_address
}