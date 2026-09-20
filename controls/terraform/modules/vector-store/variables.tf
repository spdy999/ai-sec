variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
}

variable "environment" {
  description = "Environment name."
  type        = string
}

variable "kms_key_arn" {
  description = "CMK encrypting the collection."
  type        = string
}

variable "vpc_id" {
  description = "VPC the collection endpoint is placed in."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets for the collection endpoint."
  type        = list(string)
}

variable "security_group_ids" {
  description = "Security groups on the collection endpoint."
  type        = list(string)
}
