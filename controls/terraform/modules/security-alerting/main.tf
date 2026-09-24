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

locals {
  namespace = "${var.name_prefix}/${var.environment}"

  detections = {
    guardrail-interventions = {
      log_group   = var.telemetry_log_group_name
      metric      = "GuardrailInterventions"
      pattern     = "{ $.event = \"question_answered\" && $.guardrail_intervened IS TRUE }"
      threshold   = var.guardrail_intervention_threshold
      period      = var.telemetry_period_seconds
      description = "Guardrail blocked several requests in one period: an injection attempt being worked through, or a caller probing the corpus."
    }

    authorization-refusals = {
      log_group   = var.telemetry_log_group_name
      metric      = "AuthorizationRefusals"
      pattern     = "{ $.event = \"authorization_refused\" }"
      threshold   = var.authorization_refusal_threshold
      period      = var.telemetry_period_seconds
      description = "The mediation layer refused several tokens in one period: a forged, expired or replayed token rather than a user mistyping one."
    }

    bedrock-access-denied = {
      log_group   = var.trail_log_group_name
      metric      = "BedrockAccessDenied"
      pattern     = "{ ($.eventSource = \"bedrock*\") && ($.errorCode = \"*AccessDenied*\") }"
      threshold   = 1
      period      = var.evaluation_period_seconds
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
  period      = each.value.period

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

# The queue is the delivery path, and deliberately the only one. An email
# subscription was tried and removed: AWS sends a confirmation link, delivers
# nothing until someone clicks it, and on this account nothing ever arrived --
# twice, including from a plain unencrypted topic created by hand as a control.
# Terraform reports such a subscription as created either way, so a green apply
# proved nothing. A same-account SQS subscription needs no confirmation, so
# this queue demonstrates that the topic delivers at all, and `receive-message`
# printing the alarm JSON is better evidence than an inbox. A real deployment
# subscribes a paging tool here; that is a subscription, not a redesign.
resource "aws_sqs_queue" "alerts" {
  name = "${var.name_prefix}-${var.environment}-security-alerts"

  # Alert bodies name identities, log groups and metric values, so the queue is
  # encrypted with the same CMK as the topic. SNS then needs the key too, which
  # is why sns.amazonaws.com is a named principal on the key policy: without it
  # the subscription is created, the alarm publishes, and the queue stays empty.
  kms_master_key_id                 = var.kms_key_arn
  kms_data_key_reuse_period_seconds = 300

  # Evidence for a demo and for the first minutes of an investigation, not a
  # record. The trail and the log group are the record.
  message_retention_seconds = 86400
}

data "aws_iam_policy_document" "queue" {
  statement {
    sid       = "AllowTheAlertTopicToDeliver"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.alerts.arn]

    principals {
      type        = "Service"
      identifiers = ["sns.amazonaws.com"]
    }

    # Service principal alone would let any topic in any account deliver here.
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_sns_topic.security.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "alerts" {
  queue_url = aws_sqs_queue.alerts.id
  policy    = data.aws_iam_policy_document.queue.json
}

resource "aws_sns_topic_subscription" "queue" {
  topic_arn = aws_sns_topic.security.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.alerts.arn
}
