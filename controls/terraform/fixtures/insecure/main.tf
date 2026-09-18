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
