output "cluster_name" {
  description = "Cluster name."
  value       = aws_eks_cluster.this.name
}

output "node_security_group_id" {
  description = "Security group carried by the worker nodes."
  value       = aws_security_group.nodes.id
}

output "cluster_security_group_id" {
  description = "Control plane ENI security group. The root module opens 443 on it for the jump host."
  value       = aws_security_group.cluster.id
}

output "oidc_provider_arn" {
  description = "IAM OIDC provider ARN, used as the federated principal in IRSA trust policies."
  value       = aws_iam_openid_connect_provider.cluster.arn
}

output "oidc_provider_url" {
  description = "OIDC issuer host with no scheme, the form IAM trust conditions require."
  value       = replace(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")
}
