variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
}

variable "environment" {
  description = "Environment name."
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes minor version for the control plane and the nodes."
  type        = string
}

variable "vpc_id" {
  description = "VPC hosting the cluster."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR. Node egress to the interface endpoints is written against this rather than 0.0.0.0/0; there is no route out of this VPC anyway, but the rule should say so."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets for the control plane ENIs and the nodes."
  type        = list(string)
}

variable "s3_prefix_list_id" {
  description = "Managed prefix list for S3 in this region. The S3 gateway endpoint is reached by route, so node egress to it needs a prefix list rule; ECR image layers come from S3, and without this the node registers and never goes Ready."
  type        = string
}

variable "kms_key_arn" {
  description = "CMK protecting etcd secrets, control plane logs and node root volumes."
  type        = string
}

variable "log_retention_days" {
  description = "Retention for the control plane log group."
  type        = number
}

variable "admin_principals" {
  description = "IAM principals granted cluster admin, keyed by a static name. Keyed rather than listed because the jump host role ARN is unknown until apply, and for_each cannot plan over an unknown key."
  type        = map(string)
  default     = {}
}

variable "node_instance_type" {
  description = "Node instance type."
  type        = string
  default     = "t3.medium"
}

variable "node_desired_size" {
  description = "Node count. One node runs the mediation layer and the admission controller comfortably; the subnets still span two AZs so this is a cost choice, not an architectural one."
  type        = number
  default     = 1
}

variable "node_capacity_type" {
  description = "ON_DEMAND or SPOT. Spot is roughly a third of the price and appropriate for a non-production cluster; switch to ON_DEMAND before a live demonstration so an interruption cannot land mid-presentation."
  type        = string
  default     = "SPOT"

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.node_capacity_type)
    error_message = "node_capacity_type must be ON_DEMAND or SPOT."
  }
}

variable "node_volume_size" {
  description = "Node root volume size in GB."
  type        = number
  default     = 20
}

variable "tags" {
  description = "Tags applied to everything the module creates."
  type        = map(string)
  default     = {}
}
