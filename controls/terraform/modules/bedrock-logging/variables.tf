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
  description = "How long the audit trail is kept, in both the log group and the trail bucket. No prompt or response text is recorded, so this bounds metadata retention rather than content retention."
  type        = number
}

variable "region" {
  description = "Region the trail lives in. Used to build the trail ARN the bucket policy pins, so the bucket cannot receive another account's or another region's logs."
  type        = string
}

variable "force_destroy_trail_bucket" {
  description = "Let terraform destroy delete the trail bucket with its object versions still in it. False everywhere a real audit trail is kept; true only for an ephemeral demo environment that exists to be torn down."
  type        = bool
  default     = false
}
