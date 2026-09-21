output "instance_id" {
  description = "Target for `aws ssm start-session`."
  value       = aws_instance.bastion.id
}

output "security_group_id" {
  description = "Jump host security group. Carries no ingress rules; the root module adds its egress."
  value       = aws_security_group.bastion.id
}

output "role_arn" {
  description = "Instance role. Named in an EKS access entry so kubectl on the jump host authenticates as a reviewed principal."
  value       = aws_iam_role.bastion.arn
}

output "role_name" {
  description = "Instance role name. The AI layer attaches the corpus ingestion policy to it by name."
  value       = aws_iam_role.bastion.name
}
