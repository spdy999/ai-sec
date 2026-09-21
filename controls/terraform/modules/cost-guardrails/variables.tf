variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
}

variable "environment" {
  description = "Environment name."
  type        = string
}

variable "monthly_budget_usd" {
  description = "Monthly cost ceiling for the platform."
  type        = number
  default     = 50
}

variable "alert_emails" {
  description = "Addresses notified when spend is forecast to breach a threshold. The default is a placeholder that must be replaced before apply; a budget whose alert goes nowhere is not a control."
  type        = list(string)
  default     = ["platform-security@example.com"]

  validation {
    condition     = length(var.alert_emails) > 0
    error_message = "At least one address must receive budget alerts."
  }
}

variable "alert_thresholds_percent" {
  description = "Forecast thresholds that trigger a notification."
  type        = list(number)
  default     = [50, 80, 100]
}


variable "existing_anomaly_monitor_arn" {
  description = "ARN of a dimensional SERVICE anomaly monitor that already exists. An account may hold only one, and AWS creates a default the first time Cost Explorer is opened, so creating a second is refused. Empty means create one."
  type        = string
  default     = ""
}
