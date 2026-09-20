output "vpc_id" {
  description = "VPC ID."
  value       = aws_vpc.this.id
}

output "private_subnet_ids" {
  description = "Private subnet IDs."
  value       = aws_subnet.private[*].id
}

output "private_route_table_ids" {
  description = "Route tables associated with gateway endpoints."
  value       = aws_route_table.private[*].id
}
