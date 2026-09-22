output "trail_arn" {
  description = "CloudTrail recording model invocations and guardrail evaluations."
  value       = aws_cloudtrail.this.arn
}

output "trail_log_group_arn" {
  description = "Log group the trail delivers to, for the SIEM subscription."
  value       = aws_cloudwatch_log_group.trail.arn
}

output "mediation_log_group_arn" {
  description = "Log group the mediation layer writes security telemetry to."
  value       = aws_cloudwatch_log_group.mediation.arn
}

output "mediation_log_group_name" {
  description = "Log group name, for the SIEM forwarder subscription."
  value       = aws_cloudwatch_log_group.mediation.name
}

output "trail_log_group_name" {
  description = "Log group name, for metric filters over the trail."
  value       = aws_cloudwatch_log_group.trail.name
}
