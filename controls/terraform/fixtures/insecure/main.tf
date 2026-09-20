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

########################################
# Coverage violations
#
# Everything below exists so that `make policy-coverage` can prove the
# remaining rules fire. Each block names the rule it exists to trigger. They are
# grouped here rather than woven above so it stays obvious that the fixture is a
# test input, not an abandoned design.
########################################

# VIOLATION 18: bedrock guardrail with no content filters at all, and a second
# one whose prompt-attack filter is set below HIGH. Neither is published as an
# immutable version, and there is no model invocation logging anywhere in the
# plan, so the audit-trail and version rules fire on the same input.
resource "aws_bedrock_guardrail" "unfiltered" {
  name                      = "genai-insecure-unfiltered"
  blocked_input_messaging   = "blocked"
  blocked_outputs_messaging = "blocked"
}

resource "aws_bedrock_guardrail" "weak_prompt_attack" {
  name                      = "genai-insecure-weak"
  blocked_input_messaging   = "blocked"
  blocked_outputs_messaging = "blocked"

  content_policy_config {
    filters_config {
      type            = "PROMPT_ATTACK"
      input_strength  = "MEDIUM"
      output_strength = "NONE"
    }
  }
}

# VIOLATION 19: an interface endpoint in a US region with private DNS off, so
# the SDK resolves the public service name anyway. Note that this is not a
# bedrock-runtime endpoint, so the "Bedrock has no private path" rule still
# fires alongside it.
resource "aws_vpc_endpoint" "s3_us_east" {
  vpc_id              = aws_vpc.insecure.id
  service_name        = "com.amazonaws.us-east-1.s3"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = false
}

# VIOLATION 20: the world can open a connection to the node security group.
resource "aws_vpc_security_group_ingress_rule" "insecure" {
  security_group_id = aws_security_group.insecure.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# VIOLATION 21: a service-wide wildcard, InvokeModel on every foundation model,
# and a model that never went through review.
resource "aws_iam_policy" "overbroad_bedrock" {
  name = "genai-assistant-insecure-bedrock"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "s3:*"
        Resource = "arn:aws:s3:::genai-assistant-rag-documents-insecure/*"
      },
      {
        Effect   = "Allow"
        Action   = "bedrock:InvokeModel"
        Resource = "arn:aws:bedrock:us-east-1::foundation-model/*"
      },
      {
        Effect   = "Allow"
        Action   = "bedrock:InvokeModel"
        Resource = "arn:aws:bedrock:us-east-1::foundation-model/meta.llama3-70b-instruct-v1:0"
      },
    ]
  })
}

# VIOLATION 22: a long-lived access key, which is the credential this platform
# exists to avoid.
resource "aws_iam_user" "ops" {
  name = "genai-insecure-ops"
}

resource "aws_iam_access_key" "ops" {
  user = aws_iam_user.ops.name
}

# VIOLATION 23: retention below the incident-investigation floor. Data
# minimisation has a lower bound as well as an upper one: a week of logs cannot
# answer a question about a breach discovered a month later.
resource "aws_cloudwatch_log_group" "short_retention" {
  name              = "/aws/bedrock/insecure/short"
  retention_in_days = 7
}

# VIOLATION 24: aws:kms with no key id, which silently falls back to the AWS
# managed key and gives the security team no grant list to audit.
resource "aws_s3_bucket" "transcripts" {
  bucket = "genai-assistant-transcripts-insecure"
}

resource "aws_s3_bucket_server_side_encryption_configuration" "transcripts" {
  bucket = aws_s3_bucket.transcripts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
  }
}

# VIOLATION 25: the vector store encrypted with an AWS owned key.
resource "aws_opensearchserverless_security_policy" "vectors_encryption" {
  name = "genai-vectors-enc-insecure"
  type = "encryption"

  policy = jsonencode({
    Rules = [{
      ResourceType = "collection"
      Resource     = ["collection/genai-vectors-insecure"]
    }]
    AWSOwnedKey = true
  })
}

# VIOLATION 26: a CMK that never rotates.
resource "aws_kms_key" "unrotated" {
  description         = "insecure fixture key"
  enable_key_rotation = false
}

# VIOLATION 27: envelope encryption configured, but not over secrets, which is
# the only resource type that matters. A cluster can look encrypted and not be.
resource "aws_eks_cluster" "partial_encryption" {
  name     = "genai-insecure-partial"
  role_arn = aws_iam_role.mediation.arn
  version  = "1.31"

  vpc_config {
    subnet_ids = [aws_subnet.insecure.id]
  }

  encryption_config {
    resources = ["config_map"]

    provider {
      key_arn = aws_kms_key.unrotated.arn
    }
  }
}

# VIOLATION 28: no metadata_options block at all, which leaves IMDSv1 available
# by default. Absence and misconfiguration are different failures, so the rule
# that catches each is proven separately.
resource "aws_launch_template" "no_metadata_options" {
  name_prefix = "genai-insecure-nometa-"
}
