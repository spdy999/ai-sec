# These three values are what the pipeline needs. The RUNBOOK says to set the
# first two as repository variables and the third is informational.

output "state_bucket" {
  description = "Set as the TF_STATE_BUCKET repository variable."
  value       = var.state_bucket_name
}

output "deploy_role_arn" {
  description = "Set as the AWS_DEPLOY_ROLE_ARN repository variable."
  value       = aws_iam_role.deploy.arn
}

output "state_kms_key_arn" {
  description = "CMK encrypting the state bucket, empty when the bucket was created elsewhere."
  value       = try(local.state_kms_key_arns[0], "")
}

output "trusted_github_subject" {
  description = "The only OIDC subject permitted to assume the deploy role."
  value       = local.github_subject
}
