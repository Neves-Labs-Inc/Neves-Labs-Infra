locals {
  # Alert when actual spend passes 80% of the limit, and when the forecast passes 100%.
  budget_alerts = [
    { notification_type = "ACTUAL", threshold = 80 },
    { notification_type = "FORECASTED", threshold = 100 },
  ]
}

resource "aws_budgets_budget" "monthly" {
  for_each = local.accounts

  name         = "${each.key}-monthly"
  budget_type  = "COST"
  time_unit    = "MONTHLY"
  limit_amount = each.value.monthly_limit_usd
  limit_unit   = "USD"

  cost_filter {
    name   = "LinkedAccount"
    values = [aws_organizations_account.this[each.key].id]
  }

  dynamic "notification" {
    for_each = local.budget_alerts

    content {
      comparison_operator        = "GREATER_THAN"
      notification_type          = notification.value.notification_type
      threshold                  = notification.value.threshold
      threshold_type             = "PERCENTAGE"
      subscriber_email_addresses = [var.alert_email]
    }
  }
}
