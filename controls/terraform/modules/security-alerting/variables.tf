variable "name_prefix" {
  description = "Prefix for resource names, and the first half of the CloudWatch metric namespace."
  type        = string
}

variable "environment" {
  description = "Environment name."
  type        = string
}

variable "account_id" {
  description = "Account ID, used to pin the topic policy so only this account's alarms may publish."
  type        = string
}

variable "kms_key_arn" {
  description = "CMK encrypting the alert topic. Its key policy must name cloudwatch.amazonaws.com, or the alarm transitions and publishes nothing."
  type        = string
}

variable "telemetry_log_group_name" {
  description = "Log group the mediation service writes security events to."
  type        = string
}

variable "trail_log_group_name" {
  description = "Log group CloudTrail delivers to."
  type        = string
}

variable "alert_emails" {
  description = "Addresses that receive security alerts. The default is a placeholder that must be replaced before apply; an alarm whose action goes nowhere is not a detection."
  type        = list(string)
  default     = ["platform-security@example.com"]

  validation {
    condition     = length(var.alert_emails) > 0
    error_message = "At least one address must receive security alerts."
  }
}

variable "evaluation_period_seconds" {
  description = "Window each alarm sums over."
  type        = number
  default     = 300
}

variable "guardrail_intervention_threshold" {
  description = "Interventions in one period before the alarm fires. Above one, because a single block is the control working as designed and paging on it trains people to ignore the alert."
  type        = number
  default     = 5
}

variable "authorization_refusal_threshold" {
  description = "Token refusals in one period before the alarm fires."
  type        = number
  default     = 5
}
