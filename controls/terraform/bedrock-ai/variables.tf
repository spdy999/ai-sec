variable "region" {
  description = "AWS region. Must be an EU region for data residency."
  type        = string
  default     = "eu-central-1"
}

variable "environment" {
  description = "Environment name. Drives naming and separation of accounts."
  type        = string
  default     = "prod"

  validation {
    condition     = contains(["dev", "test", "prod"], var.environment)
    error_message = "environment must be one of dev, test, prod."
  }
}

variable "offline_plan" {
  description = "Skip AWS credential/account lookups so `terraform plan` works with no account. Set false for real deployments."
  type        = bool
  default     = true
}

variable "name_prefix" {
  description = "Prefix for all resource names."
  type        = string
  default     = "genai-assistant"
}

variable "approved_model_ids" {
  description = "Bedrock model IDs the platform is allowed to invoke. Enforced in IAM and by policy-as-code."
  type        = list(string)
  default = [
    "anthropic.claude-sonnet-4-5-20250929-v1:0",
    "amazon.titan-embed-text-v2:0",
  ]
}

variable "vpc_id" {
  description = "VPC that hosts the EKS worker nodes running the mediation layer."
  type        = string
  default     = "vpc-0synthetic0example0"
}

variable "private_subnet_ids" {
  description = "Private subnets (no IGW route) used for VPC endpoints and EKS nodes."
  type        = list(string)
  default     = ["subnet-0synthetic0a", "subnet-0synthetic0b"]
}

variable "eks_oidc_provider_arn" {
  description = "OIDC provider ARN of the EKS cluster, used for IRSA workload identity."
  type        = string
  default     = "arn:aws:iam::000000000000:oidc-provider/oidc.eks.eu-central-1.amazonaws.com/id/SYNTHETICEXAMPLE"
}

variable "eks_oidc_provider_url" {
  description = "OIDC issuer host of the EKS cluster (no https:// prefix)."
  type        = string
  default     = "oidc.eks.eu-central-1.amazonaws.com/id/SYNTHETICEXAMPLE"
}

variable "service_namespace" {
  description = "Kubernetes namespace of the AI mediation layer."
  type        = string
  default     = "genai-platform"
}

variable "service_account_name" {
  description = "Kubernetes service account of the AI mediation layer."
  type        = string
  default     = "genai-mediation"
}

variable "log_retention_days" {
  description = "CloudWatch retention for AI platform logs. Bounded to satisfy data minimisation."
  type        = number
  default     = 90
}

variable "account_id" {
  description = "AWS account ID hosting the AI platform. Passed in rather than read via a data source so `terraform plan` works with no credentials."
  type        = string
  default     = "000000000000"

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be a 12 digit AWS account ID."
  }
}

variable "eks_node_security_group_id" {
  description = "Security group of the EKS nodes running the mediation layer. Only this SG may reach the VPC endpoints."
  type        = string
  default     = "sg-0synthetic0nodes0"
}

variable "endpoint_az_count" {
  description = "AZs that receive endpoint ENIs. Each ENI bills hourly. Must not exceed the number of private subnets."
  type        = number
  default     = 1
}

variable "vector_store_standby_replicas" {
  description = "OpenSearch Serverless redundancy. ENABLED provisions 4 OCUs and is the most expensive default in this platform; DISABLED halves it."
  type        = string
  default     = "DISABLED"
}

variable "corpus_source_dir" {
  description = "Synthetic corpus uploaded into the RAG bucket, relative to this root. Empty uploads nothing."
  type        = string
  default     = "../../data/corpus"
}

variable "ingestion_role_arn" {
  description = "Principal permitted to write vectors. The jump host role, wired from the platform layer: indexing the corpus is an operator action, so the running service can never write to the vector store and a prompt injection cannot poison it. Synthetic default so the layer plans offline."
  type        = string
  default     = "arn:aws:iam::000000000000:role/genai-assistant-prod-bastion"
}

variable "ingestion_role_name" {
  description = "Name of the same role. Terraform attaches a policy by name, and only the ARN crosses the layer boundary otherwise."
  type        = string
  default     = "genai-assistant-prod-bastion"
}

variable "index_name" {
  description = "OpenSearch index holding the corpus embeddings."
  type        = string
  default     = "genai-corpus"
}

variable "embedding_model_id" {
  description = "Model that turns documents and questions into vectors. Must appear in approved_model_ids; the policy gate checks the list, not this variable."
  type        = string
  default     = "amazon.titan-embed-text-v2:0"
}

variable "chat_model_id" {
  description = "Model that answers. Must appear in approved_model_ids."
  type        = string
  default     = "anthropic.claude-sonnet-4-5-20250929-v1:0"
}

variable "ephemeral_environment" {
  description = "True when this deployment exists to be torn down again -- the demo account. It lets terraform destroy delete the CloudTrail bucket with its object versions still in it. Left false, a teardown fails on BucketNotEmpty and stops before the cluster layer, which is the correct behaviour for a real audit log store and the wrong one for a lab."
  type        = bool
  default     = false
}
