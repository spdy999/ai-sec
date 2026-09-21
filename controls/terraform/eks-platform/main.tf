########################################
# EKS platform layer
#
# Where code runs: the network, the Kubernetes control plane, and the nodes
# under it. Owned by the platform team, and deployed first.
#
# It knows nothing about Bedrock, guardrails or documents. Everything it
# produces is handed to ../bedrock-ai as plain variables, and nothing comes
# back.
#
# Read top to bottom, this file is the left half of the architecture diagram.
########################################

module "encryption" {
  source = "../modules/encryption-key"

  alias       = "${var.name_prefix}-platform-${var.environment}"
  description = "CMK for ${var.name_prefix} cluster secrets and platform logs"
  account_id  = var.account_id
  region      = var.region

  # EKS uses the key to envelope-encrypt Kubernetes Secrets.
  service_principals = ["eks.amazonaws.com"]

  # Auto Scaling attaches the nodes' encrypted root volumes, acting as its own
  # service-linked role rather than as whoever ran apply.
  autoscaling_ebs_access = true
}

# A VPC with no internet gateway, no NAT gateway and no default route.
module "network" {
  source = "../modules/network"

  name_prefix          = var.name_prefix
  environment          = var.environment
  vpc_cidr             = var.vpc_cidr
  availability_zones   = var.availability_zones
  private_subnet_cidrs = var.private_subnet_cidrs

  kms_key_arn        = module.encryption.arn
  log_retention_days = var.log_retention_days
}

# Private API server, CMK-encrypted Secrets, full control plane audit logging,
# managed addons and the node group. Built on terraform-aws-modules/eks.
module "eks" {
  source = "../modules/eks-cluster"

  name_prefix        = var.name_prefix
  environment        = var.environment
  kubernetes_version = var.kubernetes_version

  vpc_id            = module.network.vpc_id
  vpc_cidr          = var.vpc_cidr
  subnet_ids        = module.network.private_subnet_ids
  s3_prefix_list_id = var.s3_prefix_list_id

  kms_key_arn        = module.encryption.arn
  log_retention_days = var.log_retention_days

  node_instance_type = var.node_instance_type
  node_desired_size  = var.node_desired_size
  node_capacity_type = var.node_capacity_type

  # The jump host is the only path to this API server, so its instance role has
  # to be a named principal here. Listing it explicitly rather than
  # bootstrapping admin from the deploy credentials is the whole point of
  # enable_cluster_creator_admin_permissions being false.
  admin_principals = merge(
    { for idx, arn in var.cluster_admin_principal_arns : "operator-${idx}" => arn },
    { bastion = module.bastion.role_arn },
  )
}

# No SSH, no public subnet, no inbound rule of any kind. The operator reaches
# this instance through Session Manager, and reaches the private API server and
# the mediation service through it.
module "bastion" {
  source = "../modules/bastion"

  name_prefix = var.name_prefix
  environment = var.environment

  vpc_id    = module.network.vpc_id
  subnet_id = module.network.private_subnet_ids[0]

  kms_key_arn   = module.encryption.arn
  ami_id        = var.bastion_ami_id
  instance_type = var.bastion_instance_type
}

# The only route out of the VPC. These services are what a node needs in
# order to boot and join the cluster with no internet access at all; the S3
# gateway endpoint is how ECR image layers are fetched.
module "endpoints" {
  source = "../modules/vpc-endpoints"

  name_prefix = var.name_prefix
  environment = var.environment
  region      = var.region

  vpc_id     = module.network.vpc_id
  subnet_ids = module.network.private_subnet_ids

  client_security_groups = {
    nodes   = module.eks.node_security_group_id
    bastion = module.bastion.security_group_id
  }

  endpoint_az_count = var.endpoint_az_count

  # ec2 is not optional: the VPC CNI calls the EC2 API to attach ENIs, and with
  # no NAT gateway there is no other route to it.
  #
  # eks is not optional either, which is not obvious and cost a provisioning
  # run to learn. Node bootstrap calls eks:DescribeCluster to discover the API
  # server endpoint and the cluster CA before the kubelet starts. Without a
  # route to it the node launches, fails to join, is replaced, and the node
  # group sits in CREATING until it times out -- with no health issue reported,
  # because nothing ever got far enough to report one.
  #
  # ssm, ssmmessages and ec2messages are the jump host's three: the agent
  # registers against ssm, the session data channel is ssmmessages, and
  # ec2messages carries Run Command. Session Manager will open a shell with only
  # the first two, but the third is what makes the host manageable rather than
  # merely reachable.
  interface_services = [
    "ec2",
    "ecr.api",
    "ecr.dkr",
    "sts",
    "logs",
    "eks",
    "ssm",
    "ssmmessages",
    "ec2messages",
  ]

  gateway_route_table_ids = module.network.private_route_table_ids
}

resource "aws_vpc_security_group_egress_rule" "bastion_to_endpoints" {
  security_group_id = module.bastion.security_group_id
  description       = "HTTPS to the SSM interface endpoints"

  referenced_security_group_id = module.endpoints.security_group_id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "bastion_to_cluster" {
  security_group_id = module.bastion.security_group_id
  description       = "kubectl to the private Kubernetes API"

  referenced_security_group_id = module.eks.cluster_security_group_id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "cluster_from_bastion" {
  security_group_id = module.eks.cluster_security_group_id
  description       = "kubectl from the operator jump host"

  referenced_security_group_id = module.bastion.security_group_id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "bastion_to_nodes" {
  security_group_id = module.bastion.security_group_id
  description       = "kubectl port-forward reaches the pod through the kubelet"

  referenced_security_group_id = module.eks.node_security_group_id
  from_port                    = 10250
  to_port                      = 10250
  ip_protocol                  = "tcp"
}

# Immutable tags, scan on push, CMK-encrypted layers, pull restricted to the
# node role. There is no route to Docker Hub from this VPC, so this is the only
# registry the cluster can pull from at all.
module "registry" {
  source = "../modules/container-registry"

  name_prefix     = var.name_prefix
  environment     = var.environment
  repository_name = "mediation"

  kms_key_arn         = module.encryption.arn
  pull_principal_arns = [module.eks.node_role_arn]
}

# Free, and the difference between a three dollar demo and a four figure
# invoice. Also the earliest signal that a stolen workload identity is being
# used to spend money on model tokens.
module "cost_guardrails" {
  source = "../modules/cost-guardrails"

  name_prefix        = var.name_prefix
  environment        = var.environment
  monthly_budget_usd = var.monthly_budget_usd
  alert_emails       = var.cost_alert_emails

  existing_anomaly_monitor_arn = var.existing_anomaly_monitor_arn
}
