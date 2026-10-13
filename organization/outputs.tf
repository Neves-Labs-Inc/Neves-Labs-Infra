output "account_ids" {
  description = "Member account name to account id."
  value       = { for name, account in aws_organizations_account.this : name => account.id }
}

output "clients_ou_id" {
  description = "Id of the adopted Clients OU."
  value       = aws_organizations_organizational_unit.clients.id
}
