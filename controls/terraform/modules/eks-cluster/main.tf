# The cluster, its nodes and its addons, built on terraform-aws-modules/eks.
#
# The hand-written version this replaces was 280 lines and correct on every
# control the policy gate checks. It was still wrong in three places that only
# a real apply found: the node security group had no egress to the S3 prefix
# list, so ECR image layers never arrived and the node sat NotReady; the CMK
# policy did not let Auto Scaling attach an encrypted root volume; and the
# default addons were never declared. Upstream gets all three right by default.
#
# What is configured below is only the security posture. Everything not named
# here is upstream's default, and upstream's defaults for this module are
# already private-endpoint, IMDSv2 and encrypted.

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = "${var.name_prefix}-${var.environment}"
  kubernetes_version = var.kubernetes_version

  vpc_id     = var.vpc_id
  subnet_ids = var.subnet_ids

  # Private only. Upstream already defaults endpoint_public_access to false;
  # stated anyway, because a default that changes upstream should break the
  # plan rather than the production posture.
  endpoint_private_access = true
  endpoint_public_access  = false

  # Dropping "audit" to save log spend would remove the only record of who
  # changed RBAC. Upstream's default omits controllerManager and scheduler.
  enabled_log_types = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler",
  ]

  create_cloudwatch_log_group            = true
  cloudwatch_log_group_retention_in_days = var.log_retention_days
  cloudwatch_log_group_kms_key_id        = var.kms_key_arn

  # Upstream would mint its own key. The platform CMK is created once, in its
  # own module, and used for etcd, logs and volumes alike so there is one key to
  # audit and one key to revoke.
  create_kms_key = false

  encryption_config = {
    provider_key_arn = var.kms_key_arn
    resources        = ["secrets"]
  }

  # Access is an explicit, reviewed grant, never inherited from whoever holds
  # the deployment credentials.
  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = false

  access_entries = {
    for name, arn in var.admin_principals : name => {
      principal_arn = arn
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  # IRSA: the cluster's OIDC issuer registered as an IAM identity provider, so a
  # service account can exchange a projected token for AWS credentials and no
  # static key exists on the node to steal.
  enable_irsa = true

  # Upstream's "recommended rules" open node egress to 0.0.0.0/0, which is the
  # exfiltration path this whole architecture exists to remove. Off, with every
  # rule named explicitly below.
  node_security_group_enable_recommended_rules = false

  node_security_group_additional_rules = {
    endpoints = {
      description                   = "HTTPS to the VPC interface endpoints"
      protocol                      = "tcp"
      from_port                     = 443
      to_port                       = 443
      type                          = "egress"
      source_cluster_security_group = false
      prefix_list_ids               = []
      cidr_blocks                   = [var.vpc_cidr]
    }

    # The S3 gateway endpoint is a route, not an ENI, so traffic to it leaves
    # the node addressed to S3 and needs a prefix list rule. Without it the
    # kubelet starts, the node registers, and it never becomes Ready, because
    # ECR serves image layers out of S3.
    s3_gateway = {
      description     = "HTTPS to S3 through the gateway endpoint, for ECR image layers"
      protocol        = "tcp"
      from_port       = 443
      to_port         = 443
      type            = "egress"
      prefix_list_ids = [var.s3_prefix_list_id]
    }

    operator_portforward = {
      description = "kubectl port-forward from the operator jump host"
      protocol    = "tcp"
      from_port   = 10250
      to_port     = 10250
      type        = "ingress"
      cidr_blocks = [var.vpc_cidr]
    }
  }

  # Declared rather than left to whatever EKS happens to pre-install. A cluster
  # whose CNI version is unmanaged is a cluster nobody can patch deliberately.
  addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni    = {}
  }

  eks_managed_node_groups = {
    mediation = {
      # Upstream would name this role "mediation-eks-node-group-<hash>", which
      # carries no platform prefix. The deploy role may only create IAM roles
      # named genai-assistant*, deliberately, so the name is pinned rather than
      # the permission widened.
      iam_role_name            = "${var.name_prefix}-${var.environment}-nodes"
      iam_role_use_name_prefix = false

      instance_types = [var.node_instance_type]
      capacity_type  = var.node_capacity_type

      min_size     = var.node_desired_size
      max_size     = var.node_desired_size + 2
      desired_size = var.node_desired_size

      block_device_mappings = {
        root = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size = var.node_volume_size
            volume_type = "gp3"
            encrypted   = true
            kms_key_id  = var.kms_key_arn
          }
        }
      }

      # IMDSv2 only, one hop. The request does not survive the container
      # boundary, so a compromised pod cannot read the node role's credentials.
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 1
        instance_metadata_tags      = "disabled"
      }

      enable_monitoring = true
    }
  }

  tags = var.tags
}
