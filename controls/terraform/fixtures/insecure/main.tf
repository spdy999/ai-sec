########################################
# DELIBERATELY INSECURE FIXTURE - DO NOT DEPLOY
#
# This module exists so the policy-as-code control can be proven to FAIL on bad
# input. A policy that has only ever returned "pass" has not been tested.
# Every resource below breaks at least one rule in ../../../policy/.
#
# Expected: `conftest test` returns a non-zero exit code with 6 failures.
########################################

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

provider "aws" {
  # VIOLATION 1: US region breaks EU data residency.
  region = "us-east-1"

  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  access_key                  = "mock-access-key"
  secret_key                  = "mock-secret-key"
}

# VIOLATION 2: no CMK, AWS-managed encryption only.
# VIOLATION 3: no public access block on a bucket holding confidential documents.
resource "aws_s3_bucket" "rag_documents" {
  bucket = "genai-assistant-rag-documents-insecure"
}

resource "aws_s3_bucket_server_side_encryption_configuration" "rag_documents" {
  bucket = aws_s3_bucket.rag_documents.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# VIOLATION 4: wildcard action and wildcard resource on the workload identity.
resource "aws_iam_policy" "mediation" {
  name = "genai-assistant-insecure-mediation"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "*"
      Resource = "*"
    }]
  })
}

# VIOLATION 5: trust policy accepts any service account in the cluster.
resource "aws_iam_role" "mediation" {
  name = "genai-assistant-insecure-mediation"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = "arn:aws:iam::000000000000:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/SYNTHETICEXAMPLE" }
      Condition = {
        StringLike = {
          "oidc.eks.us-east-1.amazonaws.com/id/SYNTHETICEXAMPLE:sub" = "system:serviceaccount:*:*"
        }
      }
    }]
  })
}

# VIOLATION 6: log group with no CMK and unbounded retention.
resource "aws_cloudwatch_log_group" "bedrock_invocations" {
  name = "/aws/bedrock/insecure/invocations"
}

# VIOLATION 7: vector store reachable from the public internet.
resource "aws_opensearchserverless_security_policy" "vectors_network" {
  name = "genai-vectors-net-insecure"
  type = "network"

  policy = jsonencode([{
    Rules = [{
      ResourceType = "collection"
      Resource     = ["collection/genai-assistant-vectors-insecure"]
    }]
    AllowFromPublic = true
  }])
}

########################################
# Platform layer violations
# These exist so every rule in ../../../policy/eks.rego can be proven to fire.
########################################

# VIOLATION 8: VPC with no flow logs, so refused connections leave no evidence.
resource "aws_vpc" "insecure" {
  cidr_block = "10.90.0.0/16"
}

# VIOLATION 9: workload subnet that hands out public IPs.
resource "aws_subnet" "insecure" {
  vpc_id                  = aws_vpc.insecure.id
  cidr_block              = "10.90.0.0/20"
  map_public_ip_on_launch = true
}

# VIOLATION 10: internet gateway restores the exfiltration path.
resource "aws_internet_gateway" "insecure" {
  vpc_id = aws_vpc.insecure.id
}

# VIOLATION 11: NAT gateway, same problem with an extra bill.
resource "aws_eip" "insecure" {
  domain = "vpc"
}

resource "aws_nat_gateway" "insecure" {
  allocation_id = aws_eip.insecure.id
  subnet_id     = aws_subnet.insecure.id
}

# VIOLATION 12: default route out of the VPC.
resource "aws_route_table" "insecure" {
  vpc_id = aws_vpc.insecure.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.insecure.id
  }
}

# VIOLATION 13: unrestricted egress, the pod can reach any host on the internet.
resource "aws_security_group" "insecure" {
  name   = "genai-insecure-nodes"
  vpc_id = aws_vpc.insecure.id
}

resource "aws_vpc_security_group_egress_rule" "insecure" {
  security_group_id = aws_security_group.insecure.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# VIOLATION 14: public API server, no secrets encryption, partial audit logging,
# aws-auth ConfigMap access, and cluster admin granted to whoever ran apply.
resource "aws_eks_cluster" "insecure" {
  name     = "genai-insecure"
  role_arn = aws_iam_role.mediation.arn
  version  = "1.31"

  enabled_cluster_log_types = ["api"]

  vpc_config {
    subnet_ids              = [aws_subnet.insecure.id]
    endpoint_public_access  = true
    endpoint_private_access = false
  }

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }
}

# VIOLATION 15: IMDSv1 available, hop limit lets the request cross into a
# container, and the root volume is unencrypted.
resource "aws_launch_template" "insecure" {
  name_prefix = "genai-insecure-"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "optional"
    http_put_response_hop_limit = 2
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size = 20
      encrypted   = false
    }
  }
}

# VIOLATION 16: vector store at full redundancy, four OCUs, billed hourly
# whether anyone queries it or not.
resource "aws_opensearchserverless_collection" "insecure" {
  name             = "genai-vectors-insecure"
  type             = "VECTORSEARCH"
  standby_replicas = "ENABLED"
}

# VIOLATION 17: confidential prompt text kept for ten years.
resource "aws_cloudwatch_log_group" "prompts_forever" {
  name              = "/aws/bedrock/insecure/prompts"
  retention_in_days = 3653
}
