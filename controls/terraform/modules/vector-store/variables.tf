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

variable "standby_replicas" {
  description = "OpenSearch Serverless redundancy. ENABLED provisions 4 OCUs (2 indexing + 2 search) and is the single most expensive default in this platform; DISABLED halves it to 2. A demo does not need standby replicas."
  type        = string
  default     = "DISABLED"

  validation {
    condition     = contains(["ENABLED", "DISABLED"], var.standby_replicas)
    error_message = "standby_replicas must be ENABLED or DISABLED."
  }
}
