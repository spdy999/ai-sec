variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
}

variable "environment" {
  description = "Environment name."
  type        = string
}

variable "account_id" {
  description = "Account ID, used to pin the Bedrock service trust to this account."
  type        = string
}

variable "kms_key_arn" {
  description = "CMK encrypting the log groups."
  type        = string
}

variable "log_retention_days" {
  description = "How long prompt and response text is kept. This number is the data minimisation trade-off."
  type        = number
}
