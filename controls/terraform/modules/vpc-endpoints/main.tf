resource "aws_security_group" "endpoints" {
  name        = "${var.name_prefix}-${var.environment}-vpce"
  description = "Interface endpoints reachable only from the named workload security group"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name_prefix}-${var.environment}-vpce"
  }
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  for_each = var.client_security_groups

  security_group_id = aws_security_group.endpoints.id
  description       = "HTTPS from ${each.key} only"

  referenced_security_group_id = each.value
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

# Endpoint ENIs answer requests; they never originate traffic. The rule exists
# because an absent egress rule is indistinguishable from an unreviewed one.
resource "aws_vpc_security_group_egress_rule" "none" {
  security_group_id = aws_security_group.endpoints.id
  description       = "Endpoint ENIs initiate no outbound traffic"

  cidr_ipv4   = "127.0.0.1/32"
  ip_protocol = "icmp"
  from_port   = 255
  to_port     = 255
}

locals {
  # One ENI per subnet per endpoint, each billed hourly.
  endpoint_subnet_ids = slice(var.subnet_ids, 0, min(var.endpoint_az_count, length(var.subnet_ids)))
}

resource "aws_vpc_endpoint" "interface" {
  for_each = toset(var.interface_services)

  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${var.region}.${each.value}"
  vpc_endpoint_type = "Interface"

  subnet_ids         = local.endpoint_subnet_ids
  security_group_ids = [aws_security_group.endpoints.id]

  # Without private DNS the SDK keeps resolving the public service name and the
  # traffic leaves the VPC, which makes the endpoint decorative.
  private_dns_enabled = true

  policy = lookup(var.endpoint_policies, each.value, null)

  tags = {
    Name = "${var.name_prefix}-${var.environment}-${replace(each.value, ".", "-")}"
  }
}

resource "aws_vpc_endpoint" "s3" {
  count = length(var.gateway_route_table_ids) > 0 ? 1 : 0

  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = var.gateway_route_table_ids

  tags = {
    Name = "${var.name_prefix}-${var.environment}-s3"
  }
}
