resource "aws_budgets_budget" "platform" {
  name         = "${var.name_prefix}-${var.environment}"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = ["user:Project$genai-assistant"]
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
# DIMENSIONAL, not CUSTOM. A CUSTOM monitor's specification only accepts the
# LINKED_ACCOUNT dimension -- naming services there fails with "Dimension not
# valid; must be scoped to 'LINKED_ACCOUNT'". Monitoring the SERVICE dimension
# is a monitor type of its own, and it watches every service rather than a
# named list, which is what is wanted here anyway: the alarming case is spend
# appearing somewhere nobody thought to list.
#
# An account may hold exactly one of these, and AWS creates a default one the
# first time Cost Explorer is opened, so a second is refused with "Limit
# exceeded on dimensional spend monitor creation". The deploy job looks for the
# existing monitor and passes its ARN; this creates one only where there is
# none.
resource "aws_ce_anomaly_monitor" "services" {
  count = var.existing_anomaly_monitor_arn == "" ? 1 : 0

  name              = "${var.name_prefix}-${var.environment}-services"
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "SERVICE"
}

locals {
  anomaly_monitor_arn = coalesce(
    var.existing_anomaly_monitor_arn,
    try(aws_ce_anomaly_monitor.services[0].arn, ""),
  )
}

resource "aws_ce_anomaly_subscription" "services" {
  name      = "${var.name_prefix}-${var.environment}-anomalies"
  frequency = "DAILY"

  monitor_arn_list = [local.anomaly_monitor_arn]

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
