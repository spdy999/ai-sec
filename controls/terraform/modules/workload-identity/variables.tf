variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
}

variable "environment" {
  description = "Environment name."
  type        = string
}

variable "region" {
  description = "Region, used to build foundation model ARNs."
  type        = string
}

variable "oidc_provider_arn" {
  description = "EKS OIDC provider ARN, the federated principal in the trust policy."
  type        = string
}

variable "oidc_provider_url" {
  description = "OIDC issuer host with no scheme."
  type        = string
}

variable "service_namespace" {
  description = "Kubernetes namespace permitted to assume this role."
  type        = string
}

variable "service_account_name" {
  description = "Kubernetes service account permitted to assume this role."
  type        = string
}

variable "approved_model_ids" {
  description = "Foundation models this identity may invoke. Governed centrally; the policy gate holds the authoritative list."
  type        = list(string)
}

variable "guardrail_id" {
  description = "Guardrail that must be attached to every model invocation."
  type        = string
}

variable "guardrail_arn" {
  description = "Guardrail ARN, for ApplyGuardrail calls."
  type        = string
}

variable "rag_bucket_arn" {
  description = "Bucket holding the source corpus."
  type        = string
}

variable "vector_collection_arn" {
  description = "Vector store collection."
  type        = string
}

variable "telemetry_log_group_arn" {
  description = "Log group the mediation layer writes security telemetry to."
  type        = string
}

variable "kms_key_arn" {
  description = "CMK the workload must be able to use to read encrypted objects."
  type        = string
}

variable "max_session_duration" {
  description = "Maximum credential lifetime in seconds."
  type        = number
  default     = 3600
}
