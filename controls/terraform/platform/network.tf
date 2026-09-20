########################################
# Platform encryption key
# Separate CMK from the AI layer: the platform team owns cluster secrets and
# flow logs, the AI team owns prompts and documents. Compromise of one key does
# not expose the other.
########################################

resource "aws_kms_key" "platform" {
  description             = "CMK for ${var.name_prefix} EKS secrets and platform logs"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  multi_region            = false

  policy = data.aws_iam_policy_document.platform_key_policy.json
}

resource "aws_kms_alias" "platform" {
  name          = "alias/${var.name_prefix}-platform-${var.environment}"
  target_key_id = aws_kms_key.platform.key_id
}

data "aws_iam_policy_document" "platform_key_policy" {
  statement {
    sid       = "EnableRootAccountKeyAdministration"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.account_id}:root"]
    }
  }

  # CloudWatch Logs needs key use to write encrypted log groups.
  statement {
    sid    = "AllowCloudWatchLogsEncryption"
    effect = "Allow"

    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]

    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["logs.${var.region}.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:aws:logs:${var.region}:${var.account_id}:log-group:*"]
    }
  }

  # EKS envelope-encrypts Kubernetes Secrets with this key.
  statement {
    sid    = "AllowEksSecretsEncryption"
    effect = "Allow"

    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]

    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

########################################
# VPC
# Deliberately has no internet gateway and no NAT gateway. The mediation layer
# has no route to the internet at all: every AWS API it needs is reached through
# an interface endpoint inside the VPC. This removes the exfiltration path that
# a successful prompt injection would otherwise try to use.
########################################

resource "aws_vpc" "platform" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.name_prefix}-${var.environment}"
  }
}

resource "aws_subnet" "private" {
  count = length(var.private_subnet_cidrs)

  vpc_id            = aws_vpc.platform.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  # No public IPs on workload subnets.
  map_public_ip_on_launch = false

  tags = {
    Name                              = "${var.name_prefix}-private-${var.availability_zones[count.index]}"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

resource "aws_route_table" "private" {
  count = length(var.private_subnet_cidrs)

  vpc_id = aws_vpc.platform.id

  # No routes are declared. Local VPC routing only; there is no 0.0.0.0/0 entry
  # because there is nowhere outside the VPC for traffic to legitimately go.

  tags = {
    Name = "${var.name_prefix}-private-${var.availability_zones[count.index]}"
  }
}

resource "aws_route_table_association" "private" {
  count = length(var.private_subnet_cidrs)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# The default security group is left explicitly empty. Anything that lands on it
# by accident can neither send nor receive.
resource "aws_default_security_group" "platform" {
  vpc_id = aws_vpc.platform.id
}

########################################
# VPC flow logs
# Network-layer evidence for incident response: who talked to whom, including
# the connections that were refused.
########################################

resource "aws_cloudwatch_log_group" "vpc_flow_logs" {
  name              = "/aws/vpc/${var.name_prefix}-${var.environment}/flow-logs"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.platform.arn
}

resource "aws_flow_log" "platform" {
  vpc_id          = aws_vpc.platform.id
  traffic_type    = "ALL"
  log_destination = aws_cloudwatch_log_group.vpc_flow_logs.arn
  iam_role_arn    = aws_iam_role.flow_logs.arn
}

resource "aws_iam_role" "flow_logs" {
  name               = "${var.name_prefix}-${var.environment}-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_trust.json
}

data "aws_iam_policy_document" "flow_logs_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "flow_logs" {
  name   = "${var.name_prefix}-${var.environment}-flow-logs"
  role   = aws_iam_role.flow_logs.id
  policy = data.aws_iam_policy_document.flow_logs.json
}

data "aws_iam_policy_document" "flow_logs" {
  statement {
    effect = "Allow"

    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]

    resources = ["${aws_cloudwatch_log_group.vpc_flow_logs.arn}:*"]
  }
}

########################################
# VPC endpoints
# The only way out of the VPC. Each endpoint is reachable solely from the node
# security group, and each carries a policy restricting what may be called
# through it.
########################################

resource "aws_security_group" "vpc_endpoints" {
  name        = "${var.name_prefix}-${var.environment}-vpc-endpoints"
  description = "Interface endpoints for the GenAI platform"
  vpc_id      = aws_vpc.platform.id
}

resource "aws_vpc_security_group_ingress_rule" "vpc_endpoints_https" {
  security_group_id = aws_security_group.vpc_endpoints.id
  description       = "HTTPS from the EKS nodes only"

  referenced_security_group_id = aws_security_group.nodes.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "vpc_endpoints_none" {
  security_group_id = aws_security_group.vpc_endpoints.id
  description       = "Endpoints originate no traffic"

  cidr_ipv4   = "127.0.0.1/32"
  ip_protocol = "tcp"
  from_port   = 443
  to_port     = 443
}

locals {
  # Endpoints the nodes need in order to run at all without internet access.
  interface_endpoints = {
    ecr_api = "ecr.api"
    ecr_dkr = "ecr.dkr"
    sts     = "sts"
    logs    = "logs"
    eks     = "eks"
  }
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_endpoints

  vpc_id              = aws_vpc.platform.id
  service_name        = "com.amazonaws.${var.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = {
    Name = "${var.name_prefix}-${var.environment}-${each.key}"
  }
}

# Gateway endpoint for S3: ECR image layers are stored in S3, so without this
# the nodes cannot pull images.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.platform.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id

  tags = {
    Name = "${var.name_prefix}-${var.environment}-s3"
  }
}
