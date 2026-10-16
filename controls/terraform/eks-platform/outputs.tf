# The interface to the AI layer in ../bedrock-ai. Passed as variables rather
# than read through a remote state data source, so that layer plans offline
# and the policy gate sees concrete strings instead of unknowns.

output "vpc_id" {
  description = "VPC hosting the mediation layer."
  value       = module.network.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnets for endpoints and nodes."
  value       = module.network.private_subnet_ids
}

output "private_route_table_ids" {
  description = "Route tables associated with gateway endpoints."
  value       = module.network.private_route_table_ids
}

output "eks_node_security_group_id" {
  description = "Node security group; the only source permitted to reach the endpoints."
  value       = module.eks.node_security_group_id
}

output "eks_cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "eks_oidc_provider_arn" {
  description = "OIDC provider ARN used for IRSA in the AI layer."
  value       = module.eks.oidc_provider_arn
}

output "eks_oidc_provider_url" {
  description = "OIDC issuer host, no scheme, as IAM trust conditions require."
  value       = module.eks.oidc_provider_url
}

output "platform_kms_key_arn" {
  description = "CMK protecting cluster secrets and platform logs."
  value       = module.encryption.arn
}

output "bastion_instance_id" {
  description = "Jump host. The target of `aws ssm start-session`; there is no other way in."
  value       = module.bastion.instance_id
}

output "mediation_repository_url" {
  description = "ECR repository the mediation image is pushed to and the nodes pull from."
  value       = module.registry.repository_url
}

output "bastion_role_arn" {
  description = "Jump host instance role. The AI layer grants it write access to the vector store, so ingestion is an operator action and the service itself can only read."
  value       = module.bastion.role_arn
}

output "bastion_role_name" {
  description = "Jump host instance role name, for the ingestion policy attachment in the AI layer."
  value       = module.bastion.role_name
}

output "bastion_security_group_id" {
  description = "Jump host security group. The AI layer adds it to the endpoint clients so the ingester can reach Bedrock and the vector store; both live behind endpoints that admit named security groups only."
  value       = module.bastion.security_group_id
}
