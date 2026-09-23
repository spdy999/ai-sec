output "topic_arn" {
  description = "SNS topic every security alarm publishes to."
  value       = aws_sns_topic.security.arn
}

output "alarm_names" {
  description = "The deployed alarms, for the runbook and for evidence."
  value = sort(concat(
    [for alarm in aws_cloudwatch_metric_alarm.detection : alarm.alarm_name],
    [aws_cloudwatch_metric_alarm.guardrail_per_subject.alarm_name],
  ))
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
