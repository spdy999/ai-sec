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

variable "account_id" {
  description = "AWS account ID hosting the platform. Passed in rather than read via a data source so `terraform plan` works with no credentials."
  type        = string
  default     = "000000000000"

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be a 12 digit AWS account ID."
  }
}

variable "vpc_cidr" {
  description = "CIDR of the platform VPC."
  type        = string
  default     = "10.80.0.0/16"
}

variable "availability_zones" {
  description = "AZs for the private subnets. Listed explicitly rather than read from a data source so plan stays offline."
  type        = list(string)
  default     = ["eu-central-1a", "eu-central-1b"]
}

variable "private_subnet_cidrs" {
  description = "CIDRs of the private subnets hosting EKS nodes and VPC endpoints."
  type        = list(string)
  default     = ["10.80.0.0/20", "10.80.16.0/20"]
}

variable "kubernetes_version" {
  description = "EKS control plane version."
  type        = string
  default     = "1.31"
}

variable "node_instance_type" {
  description = "Instance type for the mediation layer node group."
  type        = string
  default     = "t3.medium"
}

variable "node_desired_size" {
  description = "Desired node count."
  type        = number
  default     = 1
}

variable "node_capacity_type" {
  description = "ON_DEMAND or SPOT. Spot costs roughly a third; switch to ON_DEMAND before a live demonstration."
  type        = string
  default     = "SPOT"
}

variable "endpoint_az_count" {
  description = "AZs that receive interface endpoint ENIs. Each ENI bills hourly, so a second AZ doubles endpoint cost. Two for production, one for a demo."
  type        = number
  default     = 1
}

variable "monthly_budget_usd" {
  description = "Monthly cost ceiling for the whole platform. Five dollars against a platform that runs at roughly seventeen a day, deliberately: the forecast thresholds breach on the first day, which proves the notification path works rather than waiting a month to find out it does not."
  type        = number
  default     = 5
}

variable "cost_alert_emails" {
  description = "Addresses notified on forecast budget breach and cost anomalies. The default is a placeholder; replace it before any apply."
  type        = list(string)
  default     = ["platform-security@example.com"]
}

variable "cluster_admin_principal_arns" {
  description = "IAM principals granted cluster admin via EKS access entries. Empty by default: access is granted explicitly, never inherited from whoever ran apply."
  type        = list(string)
  default     = []
}

variable "log_retention_days" {
  description = "CloudWatch retention for platform logs. Bounded to satisfy data minimisation."
  type        = number
  default     = 90
}

variable "bastion_ami_id" {
  description = "AMI for the operator jump host. Read from an SSM public parameter by the deploy job and written into ci.auto.tfvars, rather than by an aws_ssm_parameter data source, because a data source that calls AWS would stop `terraform plan` from running offline. The default is a placeholder: it renders a plan and fails an apply."
  type        = string
  default     = "ami-00000000000000000"
}

variable "bastion_instance_type" {
  description = "Jump host instance type."
  type        = string
  default     = "t3.micro"
}

variable "existing_anomaly_monitor_arn" {
  description = "Dimensional SERVICE anomaly monitor to reuse. An account holds at most one, and AWS creates a default the first time Cost Explorer is opened. Resolved by the deploy job; empty means create one."
  type        = string
  default     = ""
}

variable "s3_prefix_list_id" {
  description = "Managed prefix list for S3 in this region. Passed in rather than read through an aws_ec2_managed_prefix_list data source, which would contact AWS during plan. The deploy job resolves it; the default is synthetic."
  type        = string
  default     = "pl-00000000"
}

variable "ephemeral_environment" {
  description = "True when this deployment exists to be torn down again -- the demo account. It lets terraform destroy delete the container registry with images still in it. Left false, a teardown fails on RepositoryNotEmptyException and strands the rest of the layer, which is the correct behaviour for a registry holding what production runs and the wrong one for a lab."
  type        = bool
  default     = false
}

variable "deploy_staging_bucket_arn" {
  description = "Bucket the app deploy workflow stages rendered manifests and a kubectl binary in. Written by tf-config.sh at deploy time from TF_STATE_BUCKET; empty offline, which leaves the jump host with no S3 grant at all."
  type        = string
  default     = ""
}

variable "deploy_staging_kms_key_arn" {
  description = "CMK encrypting the staging bucket. Written by tf-config.sh at deploy time from TF_STATE_KMS_KEY_ARN; empty offline."
  type        = string
  default     = ""
}
