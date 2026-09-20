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
  description = "Private subnets for the endpoint ENIs."
  type        = list(string)
}

variable "client_security_group_id" {
  description = "The only security group permitted to reach these endpoints on 443."
  type        = string
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
