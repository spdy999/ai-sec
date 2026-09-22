# Detection content for the platform's own security events.
#
# The trail and the telemetry log group record what happened. Until something
# reads them and raises an alarm, an audit trail is evidence for an
# investigation nobody has started. This module is the part that notices.
#
# Three signals, chosen because each is the observable form of a risk in
# risk-assessment.md rather than because CloudWatch offers a metric:
#
#   * guardrail interventions - a burst is someone working through injection
#     phrasings, and a sustained zero after a deploy is the guardrail silently
#     falling back to scanning nothing, which is R1.
#   * authorization refusals - the mediation layer rejecting tokens. Repeated
#     refusals for the same identity is what a stolen or forged token looks
#     like from this side.
#   * AccessDenied against Bedrock in the trail - the workload identity being
#     used for something it was not granted, which is the detective half of R3.
#
# Metric filters emit default_value = 0 on every evaluation, so an alarm has a
# datapoint even when nothing matched. Without it the alarm sits in
# INSUFFICIENT_DATA and reads as healthy on a dashboard.

resource "aws_sns_topic" "security" {
  name = "${var.name_prefix}-${var.environment}-security-alerts"

  # Alert bodies name identities and log groups. Encrypted with the platform
  # CMK, which is why cloudwatch.amazonaws.com must be a named principal on the
  # key policy: the alarm publishes as the service, not as the account.
  kms_master_key_id = var.kms_key_arn
}

data "aws_iam_policy_document" "topic" {
  statement {
    sid       = "AllowCloudWatchAlarmsToPublish"
    effect    = "Allow"
    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.security.arn]

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }

    # Any account's alarm could otherwise name this topic.
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceOwner"
      values   = [var.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "security" {
  arn    = aws_sns_topic.security.arn
  policy = data.aws_iam_policy_document.topic.json
}

# Email confirmation is a manual step: AWS sends a confirmation link and
# delivers nothing until someone clicks it. Terraform reports the subscription
# as created either way, so a green apply is not proof the alert arrives.
resource "aws_sns_topic_subscription" "email" {
  for_each = toset(var.alert_emails)

  topic_arn = aws_sns_topic.security.arn
  protocol  = "email"
  endpoint  = each.value
}

locals {
  namespace = "${var.name_prefix}/${var.environment}"

  detections = {
    guardrail-interventions = {
      log_group   = var.telemetry_log_group_name
      metric      = "GuardrailInterventions"
      pattern     = "{ $.event = \"question_answered\" && $.guardrail_intervened IS TRUE }"
      threshold   = var.guardrail_intervention_threshold
      description = "Guardrail blocked several requests in one period: an injection attempt being worked through, or a caller probing the corpus."
    }

    authorization-refusals = {
      log_group   = var.telemetry_log_group_name
      metric      = "AuthorizationRefusals"
      pattern     = "{ $.event = \"authorization_refused\" }"
      threshold   = var.authorization_refusal_threshold
      description = "The mediation layer refused several tokens in one period: a forged, expired or replayed token rather than a user mistyping one."
    }

    bedrock-access-denied = {
      log_group   = var.trail_log_group_name
      metric      = "BedrockAccessDenied"
      pattern     = "{ ($.eventSource = \"bedrock*\") && ($.errorCode = \"*AccessDenied*\") }"
      threshold   = 1
      description = "A principal was refused a Bedrock call. The workload's own path is authorised, so this is an identity being used for something it was not granted."
    }
  }
}

resource "aws_cloudwatch_log_metric_filter" "detection" {
  for_each = local.detections

  name           = "${var.name_prefix}-${var.environment}-${each.key}"
  log_group_name = each.value.log_group
  pattern        = each.value.pattern

  metric_transformation {
    name          = each.value.metric
    namespace     = local.namespace
    value         = "1"
    default_value = 0
    unit          = "Count"
  }
}

resource "aws_cloudwatch_metric_alarm" "detection" {
  for_each = local.detections

  alarm_name        = "${var.name_prefix}-${var.environment}-${each.key}"
  alarm_description = each.value.description

  namespace   = local.namespace
  metric_name = each.value.metric
  statistic   = "Sum"
  period      = var.evaluation_period_seconds

  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = each.value.threshold
  evaluation_periods  = 1

  # The filters emit zero rather than nothing, so missing data means the log
  # group stopped being written to at all. That is itself worth knowing, and
  # notBreaching would hide it; missing keeps the alarm's last known state.
  treat_missing_data = "missing"

  alarm_actions = [aws_sns_topic.security.arn]
  ok_actions    = [aws_sns_topic.security.arn]

  depends_on = [aws_cloudwatch_log_metric_filter.detection]
}
