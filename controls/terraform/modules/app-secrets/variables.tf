variable "name_prefix" {
  description = "Prefix for secret names."
  type        = string
}

variable "environment" {
  description = "Environment name."
  type        = string
}

variable "kms_key_arn" {
  description = "CMK that encrypts both secrets. Never the aws/secretsmanager default."
  type        = string
}

variable "reader_role_arns" {
  description = "The only principals the resource policy lets read these secrets. The workload role, and whatever writes the values in the first place."
  type        = list(string)

  validation {
    condition     = length(var.reader_role_arns) > 0
    error_message = "reader_role_arns must name at least one principal, or nothing can read the secrets."
  }
}

variable "ephemeral_environment" {
  description = "True in the demo account, where a destroy must not leave a name locked for a recovery window. False everywhere a deleted secret should be recoverable."
  type        = bool
  default     = false
}
