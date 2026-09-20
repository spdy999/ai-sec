variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
}

variable "environment" {
  description = "Environment name."
  type        = string
}

variable "cluster_name" {
  description = "Cluster this node group joins."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets for the nodes."
  type        = list(string)
}

variable "security_group_id" {
  description = "Node security group, created alongside the cluster security group."
  type        = string
}

variable "kms_key_arn" {
  description = "CMK encrypting the node root volumes."
  type        = string
}

variable "instance_type" {
  description = "Node instance type."
  type        = string
  default     = "t3.medium"
}

variable "desired_size" {
  description = "Node count. One node runs the mediation layer and the admission controller comfortably; the subnets still span two AZs so this is a cost choice, not an architectural one."
  type        = number
  default     = 1
}

variable "capacity_type" {
  description = "ON_DEMAND or SPOT. Spot is roughly a third of the price and appropriate for a non-production cluster; switch to ON_DEMAND before a live demonstration so an interruption cannot land mid-presentation."
  type        = string
  default     = "SPOT"

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.capacity_type)
    error_message = "capacity_type must be ON_DEMAND or SPOT."
  }
}

variable "volume_size" {
  description = "Root volume size in GB."
  type        = number
  default     = 20
}
