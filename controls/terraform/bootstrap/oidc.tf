# GitHub Actions federation.
#
# The point of this file is that the repository holds no AWS access key. A
# workflow job presents a short-lived OIDC token, AWS verifies it against
# GitHub's issuer, and the session expires with the job. There is nothing to
# leak from repository secrets because there is nothing in them.

# An account may already have this provider - it is one per account, not one
# per repository. Set create_oidc_provider = false and pass the existing ARN
# rather than fighting over ownership of a shared resource.
resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  # AWS verifies GitHub's certificate chain against its own trusted CA store,
  # so these values no longer gate the trust. They remain required arguments.
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]
}

locals {
  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : var.existing_oidc_provider_arn

  # repo:owner/name:environment:production
  #
  # Pinning the environment and not only the branch is what stops a new job in
  # this same repository from assuming the role by accident: a job without
  # `environment: production` receives a token with a different subject.
  github_subject = "repo:${var.github_owner}/${var.github_repository}:environment:${var.github_environment}"
}

data "aws_iam_policy_document" "deploy_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # StringEquals, not StringLike. A wildcard here is the classic way this
    # role gets assumed by a fork or by a pull request from an outside branch.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [local.github_subject]
    }
  }
}

resource "aws_iam_role" "deploy" {
  name                 = "genai-assistant-github-deploy"
  description          = "Assumed by GitHub Actions to apply and destroy the GenAI platform"
  assume_role_policy   = data.aws_iam_policy_document.deploy_trust.json
  max_session_duration = 3600
}

# State access is separated from infrastructure access so the two can be read
# independently: this half is what the backend needs, and nothing more.
data "aws_iam_policy_document" "deploy_state" {
  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketVersioning"]
    resources = [aws_s3_bucket.state.arn]
  }

  statement {
    effect = "Allow"

    # DeleteObject is required: S3 native locking writes a .tflock object for
    # the duration of an apply and removes it afterwards.
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]

    resources = ["${aws_s3_bucket.state.arn}/*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [aws_kms_key.state.arn]
  }
}

resource "aws_iam_role_policy" "deploy_state" {
  name   = "terraform-state"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy_state.json
}

# The infrastructure half.
#
# Honest description of what this is: service-scoped, not resource-scoped. The
# two roots create VPCs, clusters, keys and roles whose ARNs do not exist until
# apply time, so a resource-scoped policy cannot be written ahead of the first
# apply. The tightening step is to run one apply, then replace these wildcards
# with the ARNs it produced. That is a deliberate follow-up, not an oversight,
# and it is called out in the risk assessment.
data "aws_iam_policy_document" "deploy_infrastructure" {
  statement {
    effect = "Allow"

    actions = [
      "ec2:*",
      "eks:*",
      "kms:*",
      "logs:*",
      "bedrock:*",
      "aoss:*",
      "budgets:*",
      "s3:*",
      "iam:*",
      "sts:GetCallerIdentity",
    ]

    resources = ["*"]
  }

  # A deploy role that can rewrite its own trust policy is not a boundary. The
  # bootstrap resources are excluded from the role that the pipeline assumes.
  statement {
    effect = "Deny"

    actions = [
      "iam:DeleteRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:AttachRolePolicy",
    ]

    resources = [aws_iam_role.deploy.arn]
  }

  statement {
    effect    = "Deny"
    actions   = ["iam:*OpenIDConnectProvider*"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "deploy_infrastructure" {
  name   = "genai-platform"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy_infrastructure.json
}
