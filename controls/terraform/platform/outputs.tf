# These outputs are the interface to the AI layer in ../. They are passed as
# variables rather than read with a remote state data source so that the AI
# layer plan stays offline and its policy checks see concrete string values.

output "vpc_id" {
  description = "VPC hosting the mediation layer."
  value       = aws_vpc.platform.id
}

output "private_subnet_ids" {
  description = "Private subnets for VPC endpoints and EKS nodes."
  value       = aws_subnet.private[*].id
}

output "private_route_table_ids" {
  description = "Route tables associated with the S3 gateway endpoint."
  value       = aws_route_table.private[*].id
}

output "eks_node_security_group_id" {
  description = "Node security group; the only source permitted to reach the endpoints."
  value       = aws_security_group.nodes.id
}

output "eks_cluster_name" {
  description = "EKS cluster name."
  value       = aws_eks_cluster.platform.name
}

output "eks_oidc_provider_arn" {
  description = "OIDC provider ARN used for IRSA in the AI layer."
  value       = aws_iam_openid_connect_provider.cluster.arn
}

output "eks_oidc_provider_url" {
  description = "OIDC issuer host, no scheme, as required in IAM trust conditions."
  value       = replace(aws_eks_cluster.platform.identity[0].oidc[0].issuer, "https://", "")
}

output "platform_kms_key_arn" {
  description = "CMK protecting cluster secrets and platform logs."
  value       = aws_kms_key.platform.arn
}
