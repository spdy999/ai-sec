variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
}

variable "environment" {
  description = "Environment name."
  type        = string
}

variable "region" {
  description = "Region, used to build service names."
  type        = string
}

variable "vpc_id" {
  description = "VPC the endpoints are placed in."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets available for endpoint ENIs."
  type        = list(string)
}

variable "endpoint_az_count" {
  description = "How many of those subnets actually receive an ENI. Each interface endpoint bills per ENI per hour, so a second AZ doubles the cost of every endpoint. Two for production, one for a demo."
  type        = number
  default     = 1

  validation {
    condition     = var.endpoint_az_count >= 1
    error_message = "At least one subnet must carry the endpoint."
  }
}

variable "client_security_groups" {
  description = "Security groups permitted to reach the endpoints on 443, keyed by a static client name. A map rather than a list because a security group ID is unknown until apply, and for_each over unknown values cannot be planned."
  type        = map(string)
}

variable "interface_services" {
  description = "Service short names to expose as interface endpoints, for example [\"sts\", \"ecr.api\"]."
  type        = list(string)
  default     = []
}

variable "endpoint_policies" {
  description = "Optional endpoint policy JSON keyed by service short name. A service with no entry gets the permissive default policy, so name every service that carries sensitive traffic."
  type        = map(string)
  default     = {}
}

variable "gateway_route_table_ids" {
  description = "Route tables for the S3 gateway endpoint. Empty means no gateway endpoint is created."
  type        = list(string)
  default     = []
}

variable "component" {
  description = "Which layer owns this set of endpoints. Both roots instantiate this module against the same VPC, so the security group name needs to distinguish them."
  type        = string
  default     = ""
}
