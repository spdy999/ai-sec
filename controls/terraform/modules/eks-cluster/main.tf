resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${var.name_prefix}-${var.environment}/cluster"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
}

resource "aws_eks_cluster" "this" {
  name     = "${var.name_prefix}-${var.environment}"
  role_arn = aws_iam_role.cluster.arn
  version  = var.kubernetes_version

  # Dropping "audit" to save log spend would remove the only record of who
  # changed RBAC.
  enabled_cluster_log_types = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler",
  ]

  vpc_config {
    subnet_ids              = var.subnet_ids
    security_group_ids      = [aws_security_group.cluster.id]
    endpoint_private_access = true
    endpoint_public_access  = false
  }

  encryption_config {
    provider {
      key_arn = var.kms_key_arn
    }

    resources = ["secrets"]
  }

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = false
  }

  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_cloudwatch_log_group.cluster,
  ]
}

# IRSA: the cluster's OIDC issuer registered as an IAM identity provider. This
# is what lets a service account exchange a projected token for AWS credentials,
# so no static key exists on the node to steal.
resource "aws_iam_openid_connect_provider" "cluster" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [var.oidc_thumbprint]
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
# Cluster networking
# The control plane and the kubelet reference each other's security group, so
# the pair is created together. Egress from the nodes to the VPC endpoints is
# wired in the root module, where both sides are known.
########################################

resource "aws_security_group" "cluster" {
  name        = "${var.name_prefix}-${var.environment}-cluster"
  description = "EKS control plane ENIs"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name_prefix}-${var.environment}-cluster" }
}

resource "aws_security_group" "nodes" {
  name        = "${var.name_prefix}-${var.environment}-nodes"
  description = "EKS worker nodes running the mediation layer"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name_prefix}-${var.environment}-nodes" }
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

########################################
# Administrative access
# Granted explicitly to named principals, never inherited from whoever holds
# the deployment credentials.
########################################

resource "aws_eks_access_entry" "admin" {
  for_each = var.admin_principals

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "admin" {
  for_each = var.admin_principals

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.admin]
}
