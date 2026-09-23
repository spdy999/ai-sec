output "topic_arns" {
  description = "SNS topics, keyed by severity. High is the one somebody carries."
  value       = local.topic_by_severity
}

output "alarm_names" {
  description = "The deployed alarms by severity, for the runbook and for evidence."
  value = {
    high = sort([for k in keys(local.high_severity) : aws_cloudwatch_metric_alarm.detection[k].alarm_name])
    low  = sort([for k in keys(local.low_severity) : aws_cloudwatch_metric_alarm.detection[k].alarm_name])
  }
}

output "metric_namespace" {
  description = "CloudWatch namespace the metric filters publish into."
  value       = local.namespace
}

output "alert_queue_url" {
  description = "Queue the alert topic also delivers to. Reading it proves the notification path end to end without a confirmation click."
  value       = aws_sqs_queue.alerts.id
}

output "alert_queue_arn" {
  description = "ARN of the alert queue."
  value       = aws_sqs_queue.alerts.arn
}
