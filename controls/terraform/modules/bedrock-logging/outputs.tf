output "invocation_log_group_arn" {
  description = "Log group holding prompt and response text."
  value       = aws_cloudwatch_log_group.invocations.arn
}

output "mediation_log_group_arn" {
  description = "Log group the mediation layer writes security telemetry to."
  value       = aws_cloudwatch_log_group.mediation.arn
}

output "mediation_log_group_name" {
  description = "Log group name, for the SIEM forwarder subscription."
  value       = aws_cloudwatch_log_group.mediation.name
}
