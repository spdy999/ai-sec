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
  description = "Node count."
  type        = number
  default     = 2
}

variable "volume_size" {
  description = "Root volume size in GB."
  type        = number
  default     = 20
}
