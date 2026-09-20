variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
}

variable "environment" {
  description = "Environment name."
  type        = string
}

variable "kubernetes_version" {
  description = "Control plane version."
  type        = string
}

variable "vpc_id" {
  description = "VPC hosting the cluster."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets for the control plane ENIs and the nodes."
  type        = list(string)
}

variable "kms_key_arn" {
  description = "CMK used to envelope-encrypt Kubernetes Secrets and the control plane log group."
  type        = string
}

variable "log_retention_days" {
  description = "Control plane log retention."
  type        = number
}

variable "admin_principal_arns" {
  description = "IAM principals granted cluster admin through access entries. Empty by default: a fresh cluster has no administrators until access is granted as a reviewed change."
  type        = list(string)
  default     = []
}

variable "oidc_thumbprint" {
  description = "Root CA thumbprint of the EKS OIDC issuer. Pinned rather than fetched with a data source so plan performs no network call."
  type        = string
  default     = "9e99a48a9960b14926bb7f3b02e22da2b0ab7280"
}
