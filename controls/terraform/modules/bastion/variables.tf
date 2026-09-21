variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
}

variable "environment" {
  description = "Environment name."
  type        = string
}

variable "vpc_id" {
  description = "VPC the jump host sits in."
  type        = string
}

variable "subnet_id" {
  description = "Private subnet for the jump host. One subnet, not a list: this is a single instance and spreading it across AZs would mean running more than one."
  type        = string
}

variable "kms_key_arn" {
  description = "CMK encrypting the root volume."
  type        = string
}

variable "ami_id" {
  description = "AMI for the jump host. Passed in rather than read from an aws_ssm_parameter data source, because a data source that calls AWS would stop `terraform plan` from running offline. The deploy job resolves the current Amazon Linux 2023 image and writes it into ci.auto.tfvars; the default here is a placeholder that only ever renders a plan."
  type        = string
}

variable "instance_type" {
  description = "Jump host instance type. It runs an SSM agent and a kubectl session, nothing else."
  type        = string
  default     = "t3.micro"
}

variable "volume_size" {
  description = "Root volume size in GB."
  type        = number
  default     = 8
}
