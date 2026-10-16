output "role_arn" {
  description = "Role ARN, annotated on the Kubernetes service account."
  value       = aws_iam_role.mediation.arn
}

output "role_name" {
  description = "Role name."
  value       = aws_iam_role.mediation.name
}
