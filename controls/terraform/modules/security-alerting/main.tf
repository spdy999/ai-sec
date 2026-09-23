# Detection content for the platform's own security events.
#
# The trail and the telemetry log group record what happened. Until something
# reads them and raises an alarm, an audit trail is evidence for an
# investigation nobody has started. This module is the part that notices.
#
# Four signals, chosen because each is the observable form of a risk in
# risk-assessment.md rather than because CloudWatch offers a metric:
#
#   * one subject crossing the guardrail threshold - somebody is working
#     through injection phrasings, attributable to an identity, which is R1.
#     Counted by the service, not by CloudWatch; see the note on the detection
#     map below for why.
#   * authorization refusals - the mediation layer rejecting tokens. Repeated
#     refusals are what a forged or replayed token looks like from this side.
#   * AccessDenied against Bedrock in the trail - the workload identity being
#     used for something it was not granted, which is the detective half of R3.
#   * fleet-wide guardrail interventions - a trend, not an incident. Its
#     sustained zero is the signal that the guardrail stopped scanning.
#
# Metric filters emit default_value = 0 on every evaluation, so an alarm has a
# datapoint even when nothing matched. Without it the alarm sits in
# INSUFFICIENT_DATA and reads as healthy on a dashboard.

# Two topics, because severity is a routing decision. Somebody carrying the
# high topic is agreeing to look now; the low topic is a weekly read. Mixed
# into one, the first false alarm teaches people to ignore both.
resource "aws_sns_topic" "security" {
  for_each = toset(["high", "low"])

  name = "${var.name_prefix}-${var.environment}-security-alerts-${each.key}"

  # Alert bodies name identities and log groups. Encrypted with the platform
  # CMK, which is why cloudwatch.amazonaws.com must be a named principal on the
  # key policy: the alarm publishes as the service, not as the account.
  kms_master_key_id = var.kms_key_arn
}

data "aws_iam_policy_document" "topic" {
  for_each = aws_sns_topic.security

  statement {
    sid       = "AllowCloudWatchAlarmsToPublish"
    effect    = "Allow"
    actions   = ["SNS:Publish"]
    resources = [each.value.arn]

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
  for_each = aws_sns_topic.security

  arn    = each.value.arn
  policy = data.aws_iam_policy_document.topic[each.key].json
}

# Email confirmation is a manual step: AWS sends a confirmation link and
# delivers nothing until someone clicks it. Terraform reports the subscription
# as created either way, so a green apply is not proof the alert arrives.
resource "aws_sns_topic_subscription" "email" {
  for_each = {
    for pair in setproduct(keys(aws_sns_topic.security), var.alert_emails) :
    "${pair[0]}:${pair[1]}" => { severity = pair[0], address = pair[1] }
  }

  topic_arn = aws_sns_topic.security[each.value.severity].arn
  protocol  = "email"
  endpoint  = each.value.address
}

locals {
  namespace = "${var.name_prefix}/${var.environment}"

  topic_by_severity = { for severity, topic in aws_sns_topic.security : severity => topic.arn }

  # Severity is the routing decision, and it is the difference between a
  # detection someone acts on and a mailbox rule. "High" means an identity is
  # doing something it should not be and a person should look now; "low" means
  # a number moved and somebody should understand why this week. One topic for
  # both trains people to ignore the one that matters.
  detections = {
    subject-guardrail-abuse = {
      severity  = "high"
      log_group = var.telemetry_log_group_name
      metric    = "SubjectGuardrailAbuse"

      # The service counts per authenticated subject and writes this event once
      # when one of them crosses its threshold. Counting the event needs no
      # dimension and no per-user alarm: one filter, one alarm, any number of
      # users. The fleet-wide sum below cannot make this distinction at all --
      # five callers blocked once each look exactly like one caller blocked
      # five times -- which is why that one is a trend signal and this is the
      # detection.
      pattern   = "{ $.event = \"subject_exceeded_guardrail_threshold\" }"
      threshold = 1
      period    = var.telemetry_period_seconds

      description = "One identity crossed the guardrail-intervention threshold and has been paused by the mediation service. The subject is in the log event. RUNBOOK.md section 8a."
    }

    authorization-refusals = {
      severity    = "high"
      log_group   = var.telemetry_log_group_name
      metric      = "AuthorizationRefusals"
      pattern     = "{ $.event = \"authorization_refused\" }"
      threshold   = var.authorization_refusal_threshold
      period      = var.telemetry_period_seconds
      description = "The mediation layer refused several tokens in one period: a forged, expired or replayed token rather than a user mistyping one. RUNBOOK.md section 8b."
    }

    bedrock-access-denied = {
      severity    = "high"
      log_group   = var.trail_log_group_name
      metric      = "BedrockAccessDenied"
      pattern     = "{ ($.eventSource = \"bedrock*\") && ($.errorCode = \"*AccessDenied*\") }"
      threshold   = 1
      period      = var.evaluation_period_seconds
      description = "A principal was refused a Bedrock call. The workload's own path is authorised, so this is an identity being used for something it was not granted. RUNBOOK.md section 8c."
    }

    guardrail-interventions = {
      severity  = "low"
      log_group = var.telemetry_log_group_name
      metric    = "GuardrailInterventions"
      pattern   = "{ $.event = \"question_answered\" && $.guardrail_intervened IS TRUE }"

      # Deliberately well above the per-subject threshold. Nobody is paged for
      # this: it answers "is a campaign under way, or has a deploy changed how
      # often the guardrail speaks up", and the matching zero is the signal
      # that the guardrail has quietly stopped scanning, which is R1.
      threshold = var.fleet_guardrail_threshold
      period    = var.evaluation_period_seconds

      description = "Fleet-wide guardrail interventions are elevated. Not attributable to one caller -- a campaign across identities, or a change in how often the guardrail fires. Review, do not page. RUNBOOK.md section 8d."
    }
  }

  high_severity = { for k, v in local.detections : k => v if v.severity == "high" }
  low_severity  = { for k, v in local.detections : k => v if v.severity == "low" }
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

  alarm_actions = [local.topic_by_severity[each.value.severity]]
  ok_actions    = [local.topic_by_severity[each.value.severity]]

  depends_on = [aws_cloudwatch_log_metric_filter.detection]
}


# The email subscription is the operational path. It is not a provable one:
# AWS sends a confirmation link, delivers nothing until someone clicks it, and
# on this account nothing ever arrived -- twice, including from a plain
# unencrypted topic created by hand as a control. A same-account SQS
# subscription needs no confirmation, so this queue is what demonstrates that
# the topic delivers at all. `receive-message` printing the alarm JSON is
# better evidence than an inbox.
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
      values   = [for topic in aws_sns_topic.security : topic.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "alerts" {
  queue_url = aws_sqs_queue.alerts.id
  policy    = data.aws_iam_policy_document.queue.json
}

# Both severities deliver here. The queue is evidence, not routing: what it
# proves is that a transition reaches a subscriber at all, and that claim is
# the same for either topic.
resource "aws_sns_topic_subscription" "queue" {
  for_each = aws_sns_topic.security

  topic_arn = each.value.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.alerts.arn
}
