resource "aws_budgets_budget" "platform" {
  name         = "${var.name_prefix}-${var.environment}"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = ["user:Project$koerber-genai-assistant"]
  }

  # Forecast alerts, so the warning arrives while there is still time to act
  # rather than after the money is spent.
  dynamic "notification" {
    for_each = var.alert_thresholds_percent

    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "FORECASTED"
      subscriber_email_addresses = var.alert_emails
    }
  }
}

# A stolen workload identity spending on an expensive model shows up here
# before it shows up anywhere else.
resource "aws_ce_anomaly_monitor" "services" {
  name         = "${var.name_prefix}-${var.environment}-services"
  monitor_type = "CUSTOM"

  monitor_specification = jsonencode({
    Dimensions = {
      Key          = "SERVICE"
      Values       = var.monitored_services
      MatchOptions = ["EQUALS"]
    }
  })
}

resource "aws_ce_anomaly_subscription" "services" {
  name      = "${var.name_prefix}-${var.environment}-anomalies"
  frequency = "DAILY"

  monitor_arn_list = [aws_ce_anomaly_monitor.services.arn]

  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      match_options = ["GREATER_THAN_OR_EQUAL"]
      values        = ["10"]
    }
  }

  dynamic "subscriber" {
    for_each = var.alert_emails

    content {
      type    = "EMAIL"
      address = subscriber.value
    }
  }
}
