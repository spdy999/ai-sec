variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
}

variable "environment" {
  description = "Environment name."
  type        = string
}

variable "repository_name" {
  description = "Repository suffix. The full name is prefix-environment-suffix."
  type        = string
}

variable "kms_key_arn" {
  description = "CMK encrypting the image layers. ECR's default is an AWS-owned key, which cannot be audited or revoked."
  type        = string
}

variable "pull_principal_arns" {
  description = "IAM principals permitted to pull. The node role, and nothing else by default."
  type        = list(string)
}

variable "retained_image_count" {
  description = "Tagged images kept before the oldest is expired."
  type        = number
  default     = 10
}
