variable "alias" {
  description = "Key alias, without the `alias/` prefix."
  type        = string
}

variable "description" {
  description = "What this key protects. Appears in the console and in CloudTrail."
  type        = string
}

variable "account_id" {
  description = "Account that owns the key. Passed in so plan needs no credentials."
  type        = string
}

variable "region" {
  description = "Region, used to scope the CloudWatch Logs service grant."
  type        = string
}

variable "log_service_access" {
  description = "Allow CloudWatch Logs to encrypt log groups with this key."
  type        = bool
  default     = true
}

variable "service_principals" {
  description = "Additional AWS service principals permitted to use the key, for example eks.amazonaws.com for envelope encryption of Kubernetes Secrets."
  type        = list(string)
  default     = []
}

variable "deletion_window_in_days" {
  description = "Recovery window after a delete request."
  type        = number
  default     = 30
}
