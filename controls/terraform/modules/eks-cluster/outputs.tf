output "cluster_name" {
  description = "Cluster name."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Private API server endpoint. Reached through the jump host, never from the internet."
  value       = module.eks.cluster_endpoint
}

output "node_security_group_id" {
  description = "Security group carried by the worker nodes."
  value       = module.eks.node_security_group_id
}

output "cluster_security_group_id" {
  description = "Control plane ENI security group. The root module opens 443 on it for the jump host."
  value       = module.eks.cluster_security_group_id
}

output "node_role_arn" {
  description = "IAM role carried by the worker nodes; the only principal permitted to pull from the registry."
  # The per-node-group role, not the module's top-level node_iam_role_arn: in
  # v21 the role is created inside the node group submodule and the top-level
  # output is null unless a shared one was asked for.
  value = module.eks.eks_managed_node_groups["mediation"].iam_role_arn
}

output "oidc_provider_arn" {
  description = "IAM OIDC provider ARN, used as the federated principal in IRSA trust policies."
  value       = module.eks.oidc_provider_arn
}

output "oidc_provider_url" {
  description = "OIDC issuer host with no scheme, the form IAM trust conditions require."
  value       = module.eks.oidc_provider
}
