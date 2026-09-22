output "topic_arn" {
  description = "SNS topic every security alarm publishes to."
  value       = aws_sns_topic.security.arn
}

output "alarm_names" {
  description = "The deployed alarms, for the runbook and for evidence."
  value       = sort([for alarm in aws_cloudwatch_metric_alarm.detection : alarm.alarm_name])
}

output "metric_namespace" {
  description = "CloudWatch namespace the metric filters publish into."
  value       = local.namespace
}
