variable "region" {
  description = "AWS region. Must be an EU region for data residency."
  type        = string
  default     = "eu-central-1"
}

variable "environment" {
  description = "Environment name. Drives naming and separation of accounts."
  type        = string
  default     = "prod"

  validation {
    condition     = contains(["dev", "test", "prod"], var.environment)
    error_message = "environment must be one of dev, test, prod."
  }
}

variable "offline_plan" {
  description = "Skip AWS credential/account lookups so `terraform plan` works with no account. Set false for real deployments."
  type        = bool
  default     = true
}

variable "name_prefix" {
  description = "Prefix for all resource names."
  type        = string
  default     = "genai-assistant"
}

variable "approved_model_ids" {
  description = "Bedrock model IDs the platform is allowed to invoke. Enforced in IAM and by policy-as-code."
  type        = list(string)
  default = [
    "anthropic.claude-sonnet-4-5-20250929-v1:0",
    "amazon.titan-embed-text-v2:0",
  ]
}

variable "vpc_id" {
  description = "VPC that hosts the EKS worker nodes running the mediation layer."
  type        = string
  default     = "vpc-0synthetic0example0"
}

variable "private_subnet_ids" {
  description = "Private subnets (no IGW route) used for VPC endpoints and EKS nodes."
  type        = list(string)
  default     = ["subnet-0synthetic0a", "subnet-0synthetic0b"]
}

variable "eks_oidc_provider_arn" {
  description = "OIDC provider ARN of the EKS cluster, used for IRSA workload identity."
  type        = string
  default     = "arn:aws:iam::000000000000:oidc-provider/oidc.eks.eu-central-1.amazonaws.com/id/SYNTHETICEXAMPLE"
}

variable "eks_oidc_provider_url" {
  description = "OIDC issuer host of the EKS cluster (no https:// prefix)."
  type        = string
  default     = "oidc.eks.eu-central-1.amazonaws.com/id/SYNTHETICEXAMPLE"
}

variable "service_namespace" {
  description = "Kubernetes namespace of the AI mediation layer."
  type        = string
  default     = "genai-platform"
}

variable "service_account_name" {
  description = "Kubernetes service account of the AI mediation layer."
  type        = string
  default     = "genai-mediation"
}

variable "log_retention_days" {
  description = "CloudWatch retention for AI platform logs. Bounded to satisfy data minimisation."
  type        = number
  default     = 90
}

variable "account_id" {
  description = "AWS account ID hosting the AI platform. Passed in rather than read via a data source so `terraform plan` works with no credentials."
  type        = string
  default     = "000000000000"

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be a 12 digit AWS account ID."
  }
}

variable "eks_node_security_group_id" {
  description = "Security group of the EKS nodes running the mediation layer. Only this SG may reach the VPC endpoints."
  type        = string
  default     = "sg-0synthetic0nodes0"
}

variable "private_route_table_ids" {
  description = "Route tables of the private subnets, associated with the S3 gateway endpoint."
  type        = list(string)
  default     = ["rtb-0synthetic0a", "rtb-0synthetic0b"]
}
