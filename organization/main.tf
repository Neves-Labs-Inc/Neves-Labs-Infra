# The organization already exists; managing it here risks overwriting its
# enabled service principals, so it is only read.
data "aws_organizations_organization" "this" {}

locals {
  root_id = data.aws_organizations_organization.this.roots[0].id

  # Single source for every per-account resource (accounts, SSO assignments, budgets).
  accounts = {
    "Neves-Labs" = {
      email_key         = "neves_labs"
      parent_id         = local.root_id
      monthly_limit_usd = 25
    }
    "tutorlink-prod" = {
      email_key         = "tutorlink_prod"
      parent_id         = aws_organizations_organizational_unit.clients.id
      monthly_limit_usd = 10
    }
    "tn-cleaning-prod" = {
      email_key         = "tn_cleaning_prod"
      parent_id         = aws_organizations_organizational_unit.clients.id
      monthly_limit_usd = 10
    }
  }
}

# Adopts the existing Clients OU instead of creating a second one.
import {
  to = aws_organizations_organizational_unit.clients
  id = "ou-3bja-eq1u7cmv"
}

resource "aws_organizations_organizational_unit" "clients" {
  name      = "Clients"
  parent_id = local.root_id

  lifecycle {
    prevent_destroy = true
  }
}

# role_name and iam_user_access_to_billing are ForceNew, so they stay unset
# (defaults: OrganizationAccountAccessRole, billing ALLOW) and must never be added.
resource "aws_organizations_account" "this" {
  for_each = local.accounts

  name      = each.key
  email     = var.account_emails[each.value.email_key]
  parent_id = each.value.parent_id

  lifecycle {
    prevent_destroy = true

    # Keys must match in both directions so a new account can't be added without its email.
    precondition {
      condition     = toset(keys(var.account_emails)) == toset([for account in local.accounts : account.email_key])
      error_message = "account_emails keys must match the email_key of every account in local.accounts. Missing: ${jsonencode(sort(tolist(setsubtract([for account in local.accounts : account.email_key], keys(var.account_emails)))))}. Unexpected: ${jsonencode(sort(tolist(setsubtract(keys(var.account_emails), [for account in local.accounts : account.email_key]))))}."
    }

    # email is ForceNew: change it with `aws account start-primary-email-update`,
    # never through Terraform.
    ignore_changes = [email]
  }
}
