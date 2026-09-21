# The only way a human reaches this VPC.
#
# There is no internet gateway, no NAT gateway and no public subnet, so there is
# also no SSH. Access is Session Manager: the agent dials out to the SSM
# endpoints, and the session is brokered back down that same connection. The
# security group therefore has no ingress rules at all -- not a restricted one,
# none -- which is the property worth showing on a diagram.
#
# Everything that decides the instance's security posture lives in the launch
# template rather than on the instance, because the policy rules that check
# IMDSv2, the metadata hop limit and volume encryption read
# `aws_launch_template`. An instance configured directly would be correct and
# unproven.

resource "aws_launch_template" "bastion" {
  name_prefix   = "${var.name_prefix}-${var.environment}-bastion-"
  image_id      = var.ami_id
  instance_type = var.instance_type

  vpc_security_group_ids = [aws_security_group.bastion.id]

  iam_instance_profile {
    name = aws_iam_instance_profile.bastion.name
  }

  metadata_options {
    http_endpoint = "enabled"

    # Same rule as the nodes: IMDSv2 only, one hop.
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size = var.volume_size
      volume_type = "gp3"
      encrypted   = true
      kms_key_id  = var.kms_key_arn
    }
  }

  monitoring {
    enabled = true
  }

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name = "${var.name_prefix}-${var.environment}-bastion"
    }
  }
}

resource "aws_instance" "bastion" {
  subnet_id = var.subnet_id

  launch_template {
    id      = aws_launch_template.bastion.id
    version = aws_launch_template.bastion.latest_version
  }

  # Stated rather than left to the subnet default. The subnet sets
  # map_public_ip_on_launch to false, but that is the subnet's property; this is
  # the instance's, and a reviewer should not have to follow the reference.
  associate_public_ip_address = false

  tags = {
    Name = "${var.name_prefix}-${var.environment}-bastion"
  }
}

########################################
# Network position
#
# No ingress. Egress is added by the root module, which is the only place that
# knows the endpoint and control plane security group IDs.
########################################

resource "aws_security_group" "bastion" {
  name        = "${var.name_prefix}-${var.environment}-bastion"
  description = "Operator jump host; reachable only through Session Manager, never inbound"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name_prefix}-${var.environment}-bastion"
  }
}

########################################
# Identity
#
# Session Manager only. No cluster permissions are attached here: access to
# Kubernetes comes from an EKS access entry naming this role, so revoking it is
# a Kubernetes-side decision with its own audit trail.
########################################

resource "aws_iam_role" "bastion" {
  name               = "${var.name_prefix}-${var.environment}-bastion"
  assume_role_policy = data.aws_iam_policy_document.bastion_trust.json
}

data "aws_iam_policy_document" "bastion_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "bastion" {
  name = "${var.name_prefix}-${var.environment}-bastion"
  role = aws_iam_role.bastion.name
}
