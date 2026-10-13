output "vpc_id" {
  description = "ID of the shared VPC."
  value       = aws_vpc.shared.id
}

output "vpc_cidr" {
  description = "CIDR block of the shared VPC."
  value       = aws_vpc.shared.cidr_block
}

output "private_subnet_ids" {
  description = "Private subnet IDs, keyed by AZ ID."
  value       = { for az_id, subnet in aws_subnet.private : az_id => subnet.id }
}

output "private_route_table_id" {
  description = "ID of the private route table, where peering routes go."
  value       = aws_route_table.private.id
}

output "postgres_security_group_id" {
  description = "ID of the neves-labs-pg security group."
  value       = aws_security_group.postgres.id
}

output "db_subnet_group_name" {
  description = "Name of the DB subnet group for neves-labs-pg."
  value       = aws_db_subnet_group.postgres.name
}

output "reserved_cidrs" {
  description = "CIDRs reserved for client app VPCs, keyed by client."
  value       = local.reserved_cidrs
}
