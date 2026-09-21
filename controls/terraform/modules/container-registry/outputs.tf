output "repository_url" {
  description = "Registry URL to tag and push against."
  value       = aws_ecr_repository.this.repository_url
}

output "arn" {
  description = "Repository ARN."
  value       = aws_ecr_repository.this.arn
}
