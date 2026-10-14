output "address" {
  description = "Hostname of the neves-labs-pg instance."
  value       = aws_db_instance.postgres.address
}

output "port" {
  description = "Port neves-labs-pg listens on."
  value       = aws_db_instance.postgres.port
}

output "availability_zone_id" {
  description = "AZ ID the instance runs in; client app subnets should share it."
  value       = data.aws_availability_zone.postgres.zone_id
}

output "admin_username" {
  description = "Master username of neves-labs-pg."
  value       = aws_db_instance.postgres.username
}

output "admin_password" {
  description = "Master password of neves-labs-pg."
  value       = random_password.admin.result
  sensitive   = true
}

output "client_passwords" {
  description = "Password per client role, keyed by client name; the roles are created later by SQL."
  value       = { for name, password in random_password.client : name => password.result }
  sensitive   = true
}

output "client_connection_limits" {
  description = "Connection limit per client role, keyed by client name, with the default applied."
  value       = { for name, client in var.clients : name => client.connection_limit }
}
