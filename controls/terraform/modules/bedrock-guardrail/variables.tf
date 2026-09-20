variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
}

variable "environment" {
  description = "Environment name."
  type        = string
}

variable "kms_key_arn" {
  description = "CMK encrypting the guardrail configuration."
  type        = string
}

variable "employee_id_pattern" {
  description = "Regex for the internal employee identifier format that must never appear in a response."
  type        = string
  default     = "KOE-[0-9]{6}"
}
