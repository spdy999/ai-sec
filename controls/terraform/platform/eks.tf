########################################
# EKS control plane
# Private API endpoint, secrets envelope-encrypted with a CMK, and every control
# plane log type shipped. The audit log is the record of who touched the cluster
# and is the primary source for the Kubernetes detections.
########################################

resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${var.name_prefix}-${var.environment}/cluster"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.platform.arn
}

resource "aws_eks_cluster" "platform" {
  name     = "${var.name_prefix}-${var.environment}"
  role_arn = aws_iam_role.cluster.arn
  version  = var.kubernetes_version

  # All five log types. Dropping "audit" to save money would remove the only
  # record of who changed RBAC.
  enabled_cluster_log_types = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler",
  ]

  vpc_config {
    subnet_ids              = aws_subnet.private[*].id
    security_group_ids      = [aws_security_group.cluster.id]
    endpoint_private_access = true

    # The Kubernetes API is not reachable from the internet. Administrative
    # access arrives over the private network, never from 0.0.0.0/0.
    endpoint_public_access = false
  }

  # Kubernetes Secrets are envelope-encrypted with the platform CMK rather than
  # being base64 at rest in etcd.
  encryption_config {
    provider {
      key_arn = aws_kms_key.platform.arn
    }
    resources = ["secrets"]
  }

  access_config {
    # API mode only: access is granted through EKS access entries, not through
    # the aws-auth ConfigMap, so cluster admission is an IAM-auditable change.
    authentication_mode = "API"

    # Whoever runs apply does not silently become cluster admin.
    bootstrap_cluster_creator_admin_permissions = false
  }

  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_cloudwatch_log_group.cluster,
  ]
}

# IRSA: the cluster's OIDC issuer registered as an IAM identity provider. This
# is what lets a Kubernetes service account assume an IAM role with no static
# credentials anywhere on the node.
resource "aws_iam_openid_connect_provider" "cluster" {
  url             = aws_eks_cluster.platform.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["9e99a48a9960b14926bb7f3b02e22da2b0ab7280"]
}

resource "aws_security_group" "cluster" {
  name        = "${var.name_prefix}-${var.environment}-cluster"
  description = "EKS control plane ENIs"
  vpc_id      = aws_vpc.platform.id
}

resource "aws_vpc_security_group_ingress_rule" "cluster_from_nodes" {
  security_group_id = aws_security_group.cluster.id
  description       = "Kubelet and node traffic to the API server"

  referenced_security_group_id = aws_security_group.nodes.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "cluster_to_nodes" {
  security_group_id = aws_security_group.cluster.id
  description       = "Control plane to kubelet"

  referenced_security_group_id = aws_security_group.nodes.id
  from_port                    = 10250
  to_port                      = 10250
  ip_protocol                  = "tcp"
}

resource "aws_iam_role" "cluster" {
  name               = "${var.name_prefix}-${var.environment}-cluster"
  assume_role_policy = data.aws_iam_policy_document.cluster_trust.json
}

data "aws_iam_policy_document" "cluster_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

########################################
# Cluster administrative access
# Granted explicitly to named principals. The default is an empty list, so a
# fresh apply produces a cluster nobody can administer until access is granted
# as a reviewed change.
########################################

resource "aws_eks_access_entry" "admin" {
  for_each = toset(var.cluster_admin_principal_arns)

  cluster_name  = aws_eks_cluster.platform.name
  principal_arn = each.value
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "admin" {
  for_each = toset(var.cluster_admin_principal_arns)

  cluster_name  = aws_eks_cluster.platform.name
  principal_arn = each.value
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.admin]
}

########################################
# Worker nodes
# IMDSv2 required with a hop limit of 1, so a compromised pod cannot read the
# node's instance credentials through the metadata service. This is the control
# that makes IRSA meaningful: without it, a pod can simply take the node role.
########################################

resource "aws_security_group" "nodes" {
  name        = "${var.name_prefix}-${var.environment}-nodes"
  description = "EKS worker nodes running the mediation layer"
  vpc_id      = aws_vpc.platform.id
}

resource "aws_vpc_security_group_ingress_rule" "nodes_from_cluster" {
  security_group_id = aws_security_group.nodes.id
  description       = "Control plane to kubelet"

  referenced_security_group_id = aws_security_group.cluster.id
  from_port                    = 10250
  to_port                      = 10250
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "nodes_from_nodes" {
  security_group_id = aws_security_group.nodes.id
  description       = "Pod to pod within the cluster"

  referenced_security_group_id = aws_security_group.nodes.id
  ip_protocol                  = "-1"
}

# Egress is restricted to the endpoint security group and to the cluster API.
# There is no 0.0.0.0/0 egress rule: a compromised pod has no route to an
# attacker-controlled host.
resource "aws_vpc_security_group_egress_rule" "nodes_to_endpoints" {
  security_group_id = aws_security_group.nodes.id
  description       = "HTTPS to VPC interface endpoints"

  referenced_security_group_id = aws_security_group.vpc_endpoints.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "nodes_to_cluster" {
  security_group_id = aws_security_group.nodes.id
  description       = "HTTPS to the Kubernetes API"

  referenced_security_group_id = aws_security_group.cluster.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "nodes_to_nodes" {
  security_group_id = aws_security_group.nodes.id
  description       = "Pod to pod within the cluster"

  referenced_security_group_id = aws_security_group.nodes.id
  ip_protocol                  = "-1"
}

resource "aws_launch_template" "nodes" {
  name_prefix = "${var.name_prefix}-${var.environment}-nodes-"

  vpc_security_group_ids = [aws_security_group.nodes.id]

  metadata_options {
    http_endpoint = "enabled"

    # IMDSv2 only, and one hop: the request dies before it reaches a container.
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size = 20
      volume_type = "gp3"
      encrypted   = true
      kms_key_id  = aws_kms_key.platform.arn
    }
  }

  monitoring {
    enabled = true
  }

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name = "${var.name_prefix}-${var.environment}-node"
    }
  }
}

resource "aws_eks_node_group" "mediation" {
  cluster_name    = aws_eks_cluster.platform.name
  node_group_name = "mediation"
  node_role_arn   = aws_iam_role.nodes.arn
  subnet_ids      = aws_subnet.private[*].id

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_desired_size
    max_size     = var.node_desired_size + 2
  }

  launch_template {
    id      = aws_launch_template.nodes.id
    version = aws_launch_template.nodes.latest_version
  }

  depends_on = [
    aws_iam_role_policy_attachment.nodes_worker,
    aws_iam_role_policy_attachment.nodes_cni,
    aws_iam_role_policy_attachment.nodes_ecr,
  ]
}

resource "aws_iam_role" "nodes" {
  name               = "${var.name_prefix}-${var.environment}-nodes"
  assume_role_policy = data.aws_iam_policy_document.nodes_trust.json
}

data "aws_iam_policy_document" "nodes_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# The node role carries only what the kubelet needs. It has no Bedrock access
# and no S3 access: those belong to the workload identity, not the host.
resource "aws_iam_role_policy_attachment" "nodes_worker" {
  role       = aws_iam_role.nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "nodes_cni" {
  role       = aws_iam_role.nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "nodes_ecr" {
  role       = aws_iam_role.nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}
