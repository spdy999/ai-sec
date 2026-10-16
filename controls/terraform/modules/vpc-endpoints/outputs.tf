output "security_group_id" {
  description = "Security group in front of the endpoint ENIs."
  value       = aws_security_group.endpoints.id
}

output "interface_endpoint_ids" {
  description = "Interface endpoint IDs keyed by service short name."
  value       = { for name, endpoint in aws_vpc_endpoint.interface : name => endpoint.id }
}
