variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
}

variable "environment" {
  description = "Environment name."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR of the VPC."
  type        = string
}

variable "availability_zones" {
  description = "AZs for the private subnets. Listed explicitly rather than discovered so plan stays offline."
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "CIDRs of the private subnets. Must align with availability_zones."
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_cidrs) >= 2
    error_message = "At least two subnets are required so the control plane and endpoints span AZs."
  }
}

variable "kms_key_arn" {
  description = "CMK encrypting the flow log group."
  type        = string
}

variable "log_retention_days" {
  description = "Flow log retention. Bounded for data minimisation."
  type        = number
}
