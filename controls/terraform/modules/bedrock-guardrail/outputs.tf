output "guardrail_id" {
  description = "Identifier the mediation layer sends on every InvokeModel call."
  value       = aws_bedrock_guardrail.this.guardrail_id
}

output "guardrail_arn" {
  description = "Guardrail ARN."
  value       = aws_bedrock_guardrail.this.guardrail_arn
}

output "guardrail_version" {
  description = "Pinned version. The mediation layer must not use DRAFT."
  value       = aws_bedrock_guardrail_version.this.version
}
