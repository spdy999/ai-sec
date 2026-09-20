output "node_role_arn" {
  description = "IAM role carried by the worker nodes."
  value       = aws_iam_role.nodes.arn
}

output "node_group_name" {
  description = "Managed node group name."
  value       = aws_eks_node_group.this.node_group_name
}
