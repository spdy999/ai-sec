output "arn" {
  description = "Key ARN, referenced by every encrypted resource."
  value       = aws_kms_key.this.arn
}

output "key_id" {
  description = "Key ID."
  value       = aws_kms_key.this.key_id
}
