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

variable "monitored_services" {
  description = "Services the anomaly monitor watches."
  type        = list(string)

  default = [
    "Amazon Bedrock",
    "Amazon OpenSearch Service",
    "Amazon Elastic Kubernetes Service",
    "Amazon Elastic Compute Cloud - Compute",
  ]
}
