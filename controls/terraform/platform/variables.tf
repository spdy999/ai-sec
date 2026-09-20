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

variable "account_id" {
  description = "AWS account ID hosting the platform. Passed in rather than read via a data source so `terraform plan` works with no credentials."
  type        = string
  default     = "000000000000"

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be a 12 digit AWS account ID."
  }
}

variable "vpc_cidr" {
  description = "CIDR of the platform VPC."
  type        = string
  default     = "10.80.0.0/16"
}

variable "availability_zones" {
  description = "AZs for the private subnets. Listed explicitly rather than read from a data source so plan stays offline."
  type        = list(string)
  default     = ["eu-central-1a", "eu-central-1b"]
}

variable "private_subnet_cidrs" {
  description = "CIDRs of the private subnets hosting EKS nodes and VPC endpoints."
  type        = list(string)
  default     = ["10.80.0.0/20", "10.80.16.0/20"]
}

variable "kubernetes_version" {
  description = "EKS control plane version."
  type        = string
  default     = "1.31"
}

variable "node_instance_type" {
  description = "Instance type for the mediation layer node group."
  type        = string
  default     = "t3.medium"
}

variable "node_desired_size" {
  description = "Desired node count."
  type        = number
  default     = 2
}

variable "cluster_admin_principal_arns" {
  description = "IAM principals granted cluster admin via EKS access entries. Empty by default: access is granted explicitly, never inherited from whoever ran apply."
  type        = list(string)
  default     = []
}

variable "log_retention_days" {
  description = "CloudWatch retention for platform logs. Bounded to satisfy data minimisation."
  type        = number
  default     = 90
}
