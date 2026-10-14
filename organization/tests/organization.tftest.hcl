mock_provider "aws" {
  override_data {
    target = data.aws_organizations_organization.this
    values = {
      roots = [{
        id           = "r-3bja"
        arn          = "arn:aws:organizations::211125623243:root/o-pfm4ezhnh7/r-3bja"
        name         = "Root"
        policy_types = []
      }]
    }
  }

  override_data {
    target = data.aws_ssoadmin_instances.this
    values = {
      arns               = ["arn:aws:sso:::instance/ssoins-0000000000000000"]
      identity_store_ids = ["d-0000000000"]
    }
  }

  override_data {
    target = data.aws_ssoadmin_permission_set.administrator_access
    values = {
      arn  = "arn:aws:sso:::permissionSet/ssoins-0000000000000000/ps-0123456789abcdef"
      name = "AdministratorAccess"
    }
  }

  override_data {
    target = data.aws_identitystore_user.admin
    values = {
      user_id = "0000000000-11111111-2222-3333-4444-555555555555"
    }
  }

  # Mock providers can't import, so the adopted OU's id is supplied here.
  # Name and parent stay unset so the plan shows the configured values.
  override_resource {
    target = aws_organizations_organizational_unit.clients
    values = {
      id = "ou-3bja-eq1u7cmv"
    }
  }

  # A valid 12-digit id for any account without its own override below (a newly
  # added client), since the budget filter rejects the mock's random ids.
  mock_resource "aws_organizations_account" {
    defaults = {
      id = "000000000099"
    }
  }

  # Distinct placeholder ids so the budget filter tests can tell accounts apart.
  override_resource {
    target = aws_organizations_account.this["Neves-Labs"]
    values = {
      id = "000000000001"
    }
  }

  override_resource {
    target = aws_organizations_account.this["tutorlink-prod"]
    values = {
      id = "000000000002"
    }
  }

  override_resource {
    target = aws_organizations_account.this["tn-cleaning-prod"]
    values = {
      id = "000000000003"
    }
  }
}

variables {
  account_emails = {
    neves_labs       = "owner+neves-labs@example.com"
    tutorlink_prod   = "owner+tutorlink-prod@example.com"
    tn_cleaning_prod = "owner+tn-cleaning-prod@example.com"
  }
  alert_email   = "owner+alerts@example.com"
  sso_user_name = "test-user"
}

run "adopts_the_clients_ou_under_the_root" {
  command = plan

  assert {
    condition     = aws_organizations_organizational_unit.clients.name == "Clients"
    error_message = "Clients OU must keep its existing name."
  }

  assert {
    condition     = aws_organizations_organizational_unit.clients.parent_id == "r-3bja"
    error_message = "Clients OU must sit directly under the org root."
  }
}

# Checks the existing accounts are present, not that they are the only ones, so adding a
# client account only needs its email key in account_emails above.
run "creates_the_member_accounts_under_their_parents" {
  command = plan

  assert {
    condition = length(setsubtract([
      "Neves-Labs",
      "tutorlink-prod",
      "tn-cleaning-prod",
    ], [for account in aws_organizations_account.this : account.name])) == 0
    error_message = "Member accounts must include Neves-Labs, tutorlink-prod and tn-cleaning-prod."
  }

  assert {
    condition     = alltrue([for name, account in aws_organizations_account.this : account.name == name])
    error_message = "Each member account must be named after its key."
  }

  assert {
    condition     = aws_organizations_account.this["Neves-Labs"].parent_id == "r-3bja"
    error_message = "Neves-Labs must sit directly under the org root."
  }

  assert {
    condition     = aws_organizations_account.this["tutorlink-prod"].parent_id == "ou-3bja-eq1u7cmv"
    error_message = "tutorlink-prod must sit in the Clients OU."
  }

  assert {
    condition     = aws_organizations_account.this["tn-cleaning-prod"].parent_id == "ou-3bja-eq1u7cmv"
    error_message = "tn-cleaning-prod must sit in the Clients OU."
  }

  assert {
    condition     = aws_organizations_account.this["tutorlink-prod"].email == "owner+tutorlink-prod@example.com"
    error_message = "Each account must take its own email from account_emails."
  }

  assert {
    condition     = toset(keys(output.account_ids)) == toset(keys(aws_organizations_account.this))
    error_message = "account_ids must map every member account name to its id."
  }
}

run "grants_administrator_access_to_the_sso_user_on_every_account" {
  command = plan

  assert {
    condition     = toset(keys(aws_ssoadmin_account_assignment.administrator)) == toset(keys(aws_organizations_account.this))
    error_message = "Expected exactly one assignment per member account."
  }

  assert {
    condition = alltrue([
      for assignment in aws_ssoadmin_account_assignment.administrator :
      assignment.instance_arn == "arn:aws:sso:::instance/ssoins-0000000000000000"
      && assignment.permission_set_arn == "arn:aws:sso:::permissionSet/ssoins-0000000000000000/ps-0123456789abcdef"
      && assignment.principal_id == "0000000000-11111111-2222-3333-4444-555555555555"
      && assignment.principal_type == "USER"
      && assignment.target_type == "AWS_ACCOUNT"
    ])
    error_message = "Every assignment must grant AdministratorAccess to the SSO user on an AWS account."
  }
}

run "rejects_an_account_email_without_a_tld" {
  command = plan

  variables {
    account_emails = {
      neves_labs       = "owner@example"
      tutorlink_prod   = "owner+tutorlink-prod@example.com"
      tn_cleaning_prod = "owner+tn-cleaning-prod@example.com"
    }
  }

  expect_failures = [var.account_emails]
}

run "rejects_an_account_email_without_an_at_sign" {
  command = plan

  variables {
    account_emails = {
      neves_labs       = "owner+neves-labs@example.com"
      tutorlink_prod   = "not-an-email"
      tn_cleaning_prod = "owner+tn-cleaning-prod@example.com"
    }
  }

  expect_failures = [var.account_emails]
}

run "rejects_account_emails_missing_an_account_key" {
  command = plan

  variables {
    account_emails = {
      neves_labs     = "owner+neves-labs@example.com"
      tutorlink_prod = "owner+tutorlink-prod@example.com"
    }
  }

  expect_failures = [aws_organizations_account.this]
}

run "rejects_account_emails_with_an_unknown_key" {
  command = plan

  variables {
    account_emails = {
      neves_labs       = "owner+neves-labs@example.com"
      tutorlink_prod   = "owner+tutorlink-prod@example.com"
      tn_cleaning_prod = "owner+tn-cleaning-prod@example.com"
      unknown_prod     = "owner+unknown-prod@example.com"
    }
  }

  expect_failures = [aws_organizations_account.this]
}

run "rejects_an_alert_email_without_an_at_sign" {
  command = plan

  variables {
    alert_email = "owner.example.com"
  }

  expect_failures = [var.alert_email]
}

run "plans_one_monthly_cost_budget_per_account_with_its_limit" {
  command = plan

  assert {
    condition = toset([for budget in aws_budgets_budget.monthly : budget.name]) == toset([
      for name in keys(aws_organizations_account.this) : "${name}-monthly"
    ])
    error_message = "Expected one <account>-monthly budget per member account."
  }

  assert {
    condition = (
      aws_budgets_budget.monthly["Neves-Labs"].limit_amount == "25"
      && aws_budgets_budget.monthly["tutorlink-prod"].limit_amount == "10"
      && aws_budgets_budget.monthly["tn-cleaning-prod"].limit_amount == "10"
    )
    error_message = "Limits must be 25 / 10 / 10 USD."
  }

  assert {
    condition = alltrue([
      for budget in aws_budgets_budget.monthly :
      budget.budget_type == "COST" && budget.time_unit == "MONTHLY" && budget.limit_unit == "USD"
    ])
    error_message = "Every budget must be a monthly USD COST budget."
  }
}

# Apply (mocked) because an account id is only known after creation.
run "scopes_each_budget_to_its_own_account" {
  command = apply

  assert {
    condition = (
      one(aws_budgets_budget.monthly["Neves-Labs"].cost_filter).name == "LinkedAccount"
      && one(one(aws_budgets_budget.monthly["Neves-Labs"].cost_filter).values) == "000000000001"
      && one(one(aws_budgets_budget.monthly["tutorlink-prod"].cost_filter).values) == "000000000002"
      && one(one(aws_budgets_budget.monthly["tn-cleaning-prod"].cost_filter).values) == "000000000003"
    )
    error_message = "Each budget must filter on its own account's LinkedAccount id."
  }
}

run "alerts_the_alert_email_at_80_percent_actual_and_100_percent_forecasted" {
  command = plan

  assert {
    condition = alltrue([
      for budget in aws_budgets_budget.monthly :
      length(budget.notification) == 2
      && length([for n in budget.notification : n if n.notification_type == "ACTUAL" && n.comparison_operator == "GREATER_THAN" && n.threshold == 80 && n.threshold_type == "PERCENTAGE"]) == 1
      && length([for n in budget.notification : n if n.notification_type == "FORECASTED" && n.comparison_operator == "GREATER_THAN" && n.threshold == 100 && n.threshold_type == "PERCENTAGE"]) == 1
      && alltrue([for n in budget.notification : n.subscriber_email_addresses == toset(["owner+alerts@example.com"])])
    ])
    error_message = "Each budget needs exactly an 80% ACTUAL and a 100% FORECASTED alert to alert_email."
  }
}
