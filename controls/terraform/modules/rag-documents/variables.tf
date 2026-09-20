variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
}

variable "environment" {
  description = "Environment name."
  type        = string
}

variable "kms_key_arn" {
  description = "CMK encrypting objects at rest."
  type        = string
}

variable "noncurrent_version_expiration_days" {
  description = "How long superseded document versions are retained. Long enough to roll back a poisoning incident, short enough to satisfy data minimisation."
  type        = number
  default     = 90
}
