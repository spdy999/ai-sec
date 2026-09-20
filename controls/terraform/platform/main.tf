########################################
# Platform layer
#
# The container platform the AI mediation service runs on. Owned by the platform
# team: a separate lifecycle, a separate key, and a separate blast radius from
# the AI layer in ../ai-platform.
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

# Private API server, CMK-encrypted Secrets, full control plane audit logging.
module "eks" {
  source = "../modules/eks-cluster"

  name_prefix        = var.name_prefix
  environment        = var.environment
  kubernetes_version = var.kubernetes_version

  vpc_id     = module.network.vpc_id
  subnet_ids = module.network.private_subnet_ids

  kms_key_arn        = module.encryption.arn
  log_retention_days = var.log_retention_days

  admin_principal_arns = var.cluster_admin_principal_arns
}

# The only route out of the VPC. These five services are what a node needs in
# order to boot and join the cluster with no internet access at all; the S3
# gateway endpoint is how ECR image layers are fetched.
module "endpoints" {
  source = "../modules/vpc-endpoints"

  name_prefix = var.name_prefix
  environment = var.environment
  region      = var.region

  vpc_id     = module.network.vpc_id
  subnet_ids = module.network.private_subnet_ids

  client_security_group_id = module.eks.node_security_group_id
  interface_services       = ["ecr.api", "ecr.dkr", "sts", "logs", "eks"]
  gateway_route_table_ids  = module.network.private_route_table_ids
}

# Wired here rather than inside either module: the node security group and the
# endpoint security group each need the other's ID, and the root module is where
# both are known.
resource "aws_vpc_security_group_egress_rule" "nodes_to_endpoints" {
  security_group_id = module.eks.node_security_group_id
  description       = "HTTPS to the VPC interface endpoints"

  referenced_security_group_id = module.endpoints.security_group_id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

# IMDSv2 required, hop limit 1, encrypted root volumes, kubelet permissions only.
module "nodes" {
  source = "../modules/eks-nodes"

  name_prefix = var.name_prefix
  environment = var.environment

  cluster_name      = module.eks.cluster_name
  subnet_ids        = module.network.private_subnet_ids
  security_group_id = module.eks.node_security_group_id
  kms_key_arn       = module.encryption.arn

  instance_type = var.node_instance_type
  desired_size  = var.node_desired_size
}
