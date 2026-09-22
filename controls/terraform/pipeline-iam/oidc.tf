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

  # GitHub issues two shapes of subject, and which one arrives is not something
  # this repository controls:
  #
  #   repo:owner/name:environment:production                     (legacy)
  #   repo:owner@<owner id>/name@<repo id>:environment:production (immutable)
  #
  # The immutable form embeds the numeric account and repository IDs so that
  # renaming either cannot silently transfer trust to a different repository.
  # Pinning only the legacy form fails with "Not authorized to perform
  # sts:AssumeRoleWithWebIdentity" and no indication of what the subject was.
  #
  # Both are listed. Values in a StringEquals condition are OR-ed, so this is
  # still two exact matches and not a wildcard: pinning the environment rather
  # than only the branch is what stops another job in this same repository
  # assuming the role by accident.
  github_subject = "repo:${var.github_owner}/${var.github_repository}:environment:${var.github_environment}"

  github_subject_immutable = format(
    "repo:%s@%s/%s@%s:environment:%s",
    var.github_owner,
    var.github_owner_id,
    var.github_repository,
    var.github_repository_id,
    var.github_environment,
  )
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

      values = [
        local.github_subject,
        local.github_subject_immutable,
      ]
    }
  }
}

resource "aws_iam_role" "deploy" {
  name                 = var.deploy_role_name
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
    resources = [local.state_bucket_arn]
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

    resources = ["${local.state_bucket_arn}/*"]
  }

  dynamic "statement" {
    for_each = local.state_kms_key_arns

    content {
      effect    = "Allow"
      actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
      resources = [statement.value]
    }
  }
}

resource "aws_iam_role_policy" "deploy_state" {
  name   = "terraform-state"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy_state.json
}

# The infrastructure half.
#
# Scoped by service, and by resource wherever the ARN is predictable. It cannot
# be scoped everywhere: `ec2:*` and `eks:*` act on resources this root has
# never seen. What it does not do is hold `iam:*` on `*` - that would let the
# pipeline mint any role in the account, which is the whole boundary.
data "aws_iam_policy_document" "deploy_infrastructure" {
  statement {
    sid    = "Infrastructure"
    effect = "Allow"

    actions = [
      "ec2:*",
      "eks:*",
      "kms:*",
      "logs:*",
      "bedrock:*",
      "aoss:*",
      "budgets:*",

      # Cost Explorer is its own service. The budget above is `budgets:*`; the
      # anomaly monitor and its subscription are `ce:*`, and neither takes a
      # resource-level ARN.
      "ce:*",

      "sts:GetCallerIdentity",

      # The deploy job resolves the jump host AMI from the public Amazon Linux
      # parameter before planning, because a data source that did it inside
      # Terraform would stop the roots planning offline.
      "ssm:GetParameter",
      "ssm:GetParameters",
    ]

    resources = ["*"]
  }

  # The AI layer creates the containers for the application's secret material
  # and attaches a resource policy to each. It never writes a value: no
  # aws_secretsmanager_secret_version exists, precisely so the plaintext stays
  # out of Terraform state, and PutSecretValue is therefore absent here. The
  # jump host holds that, and generates the material inside the VPC.
  #
  # Scoped to this platform's own names. Secret ARNs carry a random six
  # character suffix, so the wildcard is on the ARN and not on the name.
  statement {
    sid    = "PlatformSecretContainersOnly"
    effect = "Allow"

    actions = [
      "secretsmanager:CreateSecret",
      "secretsmanager:DeleteSecret",
      "secretsmanager:DescribeSecret",
      "secretsmanager:UpdateSecret",
      "secretsmanager:TagResource",
      "secretsmanager:UntagResource",
      "secretsmanager:GetResourcePolicy",
      "secretsmanager:PutResourcePolicy",
      "secretsmanager:DeleteResourcePolicy",
    ]

    resources = [
      "arn:aws:secretsmanager:${var.region}:${var.account_id}:secret:${var.name_prefix}/*",
    ]
  }

  # Applying workload manifests means reaching a private API server, which no
  # GitHub runner can do. The deploy job sends a command to the jump host
  # instead and reads the result back. Scoped to the platform's own instances:
  # SendCommand on "*" would let this role run a shell on anything in the
  # account that happens to run an SSM agent.
  statement {
    sid    = "RunDeployCommandsOnThePlatformJumpHost"
    effect = "Allow"

    actions = ["ssm:SendCommand"]

    resources = [
      "arn:aws:ssm:${var.region}::document/AWS-RunShellScript",
      "arn:aws:ec2:${var.region}:${var.account_id}:instance/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Name"
      values   = ["${var.name_prefix}-prod-bastion"]
    }
  }

  # Reading a command's own result carries no such risk, and the command id is
  # not knowable in advance.
  statement {
    sid       = "ReadOwnCommandResults"
    effect    = "Allow"
    actions   = ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations"]
    resources = ["*"]
  }

  # The OpenSearch Serverless VPC endpoint publishes its private DNS through a
  # Route 53 private hosted zone that the service creates and owns. Terraform
  # waits on the endpoint reaching ACTIVE, and the endpoint instead reaches
  # FAILED with ACCESS_DENIED on route53:ListHostedZonesByVPC when the caller
  # cannot see that zone. Named actions rather than route53:*, and no ARN,
  # because the zone does not exist until the endpoint creates it.
  statement {
    sid    = "PrivateDnsForServiceEndpoints"
    effect = "Allow"

    actions = [
      "route53:ListHostedZonesByVPC",
      "route53:ListHostedZones",
      "route53:GetHostedZone",
      "route53:CreateHostedZone",
      "route53:DeleteHostedZone",
      "route53:AssociateVPCWithHostedZone",
      "route53:DisassociateVPCFromHostedZone",
      "route53:ChangeResourceRecordSets",
      "route53:ListResourceRecordSets",
      "route53:GetChange",
    ]

    resources = ["*"]
  }

  # Only roles and policies carrying the platform's own name prefix.
  statement {
    sid    = "IamForPlatformRoles"
    effect = "Allow"

    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:UpdateRole",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:GetRolePolicy",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:ListPolicyVersions",
      "iam:TagPolicy",

      # The jump host carries an instance profile. It is a third IAM resource
      # type, so the prefix has to be named for it as well or EC2 has no way to
      # hand the instance its role.
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:GetInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile",
      "iam:ListInstanceProfilesForRole",
    ]

    resources = [
      "arn:aws:iam::${var.account_id}:role/${var.name_prefix}*",
      "arn:aws:iam::${var.account_id}:policy/${var.name_prefix}*",
      "arn:aws:iam::${var.account_id}:instance-profile/${var.name_prefix}*",
    ]
  }

  # PassRole is the action that turns "can create a role" into "can become
  # anything". Conditioned on the service it is being passed to.
  statement {
    sid       = "PassOnlyToAwsServices"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${var.account_id}:role/${var.name_prefix}*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values = [
        "eks.amazonaws.com",
        "ec2.amazonaws.com",

        # VPC flow logs run as their own service principal and are passed the
        # delivery role. Without this the VPC applies and the flow log that
        # makes it auditable does not.
        "vpc-flow-logs.amazonaws.com",

        # Bedrock is passed a role so it can write invocation logs. Same shape:
        # the model layer applies and the record of what was asked of it does
        # not.
        "bedrock.amazonaws.com",

        # CloudTrail is passed the role it assumes to mirror events into the
        # CloudWatch log group the SIEM subscribes to. The trail writes to S3
        # as itself; only the log group delivery needs a role.
        "cloudtrail.amazonaws.com",
      ]
    }
  }

  # Creating the repository is Terraform's job and is covered above by
  # ec2/eks-style wildcards being absent here on purpose: ECR is split in two.
  # GetAuthorizationToken has no resource of its own -- it mints the docker
  # login for the whole registry -- so it can only be granted on "*". Everything
  # that acts on images is scoped to the platform's own repositories.
  statement {
    sid       = "EcrLogin"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "EcrOwnRepositoriesOnly"
    effect = "Allow"

    actions = [
      "ecr:CreateRepository",
      "ecr:DeleteRepository",
      "ecr:DescribeRepositories",
      "ecr:TagResource",
      "ecr:UntagResource",
      "ecr:ListTagsForResource",
      "ecr:PutImageTagMutability",
      "ecr:PutImageScanningConfiguration",
      "ecr:GetLifecyclePolicy",
      "ecr:PutLifecyclePolicy",
      "ecr:DeleteLifecyclePolicy",
      "ecr:GetRepositoryPolicy",
      "ecr:SetRepositoryPolicy",
      "ecr:DeleteRepositoryPolicy",

      # The image build pushes with these.
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:BatchGetImage",
      "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer",
    ]

    resources = ["arn:aws:ecr:*:${var.account_id}:repository/${var.name_prefix}*"]
  }

  # OpenSearch Serverless data access policies are a separate API from the
  # collection itself, and `aoss:*` in the Infrastructure statement above covers
  # both. Named here only so the next reader does not go looking for a gap.

  # The AI layer creates the RAG corpus bucket. Scoped to the platform's own
  # name prefix, so the role cannot touch the state bucket's neighbours or any
  # unrelated bucket in the account.
  statement {
    sid    = "RagCorpusBucket"
    effect = "Allow"

    actions = ["s3:*"]

    resources = [
      "arn:aws:s3:::${var.name_prefix}-*",
      "arn:aws:s3:::${var.name_prefix}-*/*",
    ]
  }

  # The AI layer's audit trail. Scoped to the platform's own trail name, so the
  # role cannot stop or delete a trail someone else created -- which is the
  # first move against an account whose only record of model use is CloudTrail.
  statement {
    sid    = "OwnAuditTrailOnly"
    effect = "Allow"

    actions = [
      "cloudtrail:CreateTrail",
      "cloudtrail:DeleteTrail",
      "cloudtrail:UpdateTrail",
      "cloudtrail:StartLogging",
      "cloudtrail:StopLogging",
      "cloudtrail:GetTrail",
      "cloudtrail:GetTrailStatus",
      "cloudtrail:GetEventSelectors",
      "cloudtrail:PutEventSelectors",
      "cloudtrail:AddTags",
      "cloudtrail:RemoveTags",
      "cloudtrail:ListTags",
    ]

    resources = ["arn:aws:cloudtrail:*:${var.account_id}:trail/${var.name_prefix}*"]
  }

  # ListTrails and DescribeTrails enumerate the account and take no resource of
  # their own. Read-only, and Terraform calls them on every refresh.
  statement {
    sid    = "EnumerateTrails"
    effect = "Allow"

    actions = [
      "cloudtrail:ListTrails",
      "cloudtrail:DescribeTrails",
    ]

    resources = ["*"]
  }

  # The cluster gets its own OIDC provider for IRSA - modules/eks-cluster
  # creates one. A blanket deny on OpenIDConnectProvider actions would break
  # the deploy, so the deny below names this role's provider instead.
  statement {
    sid    = "ClusterOidcProvider"
    effect = "Allow"

    actions = [
      "iam:CreateOpenIDConnectProvider",
      "iam:DeleteOpenIDConnectProvider",
      "iam:GetOpenIDConnectProvider",
      "iam:TagOpenIDConnectProvider",
      "iam:ListOpenIDConnectProviders",
    ]

    resources = ["*"]
  }

  statement {
    sid    = "ServiceLinkedRolesForNamedServicesOnly"
    effect = "Allow"

    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["arn:aws:iam::${var.account_id}:role/aws-service-role/*"]

    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"

      values = [
        "eks.amazonaws.com",
        "eks-nodegroup.amazonaws.com",
        "spot.amazonaws.com",
        "observability.aoss.amazonaws.com",
      ]
    }
  }

  # CreateNodegroup checks whether the service-linked role already exists before
  # creating it, and reports the missing read as
  #
  #   InvalidRequestException: Failed to validate if SLR:
  #   AWSServiceRoleForAmazonEKSNodegroup already exists due to missing
  #   permissions for 'iam:GetRole'
  #
  # which reads like a validation bug rather than a permissions one.
  #
  # Two resources, and the second is the one that matters. The role does not
  # exist yet at the moment of the check, so IAM has no path to resolve and
  # authorises against the bare name:
  #
  #   arn:aws:iam::<account>:role/AWSServiceRoleForAmazonEKSNodegroup
  #
  # not the /aws-service-role/ form the role will have once created. Granting
  # only the path fails, and `iam:simulate-principal-policy` on the path form
  # says "allowed", which is how this survives two rounds of looking correct.
  #
  # Also its own statement rather than folded into CreateServiceLinkedRole
  # above: that statement's iam:AWSServiceName condition does not hold for a
  # read.
  statement {
    sid     = "ReadServiceLinkedRoles"
    effect  = "Allow"
    actions = ["iam:GetRole"]

    resources = [
      "arn:aws:iam::${var.account_id}:role/aws-service-role/*",
      "arn:aws:iam::${var.account_id}:role/AWSServiceRole*",
    ]
  }

  # The state bucket shares the name prefix, so the grant above reaches it.
  # The role must read and write state objects there, but it must not be able
  # to delete the bucket it stores its own state in, or unpick its protections.
  statement {
    sid    = "ProtectTheStateBucketItself"
    effect = "Deny"

    actions = [
      "s3:DeleteBucket",
      "s3:PutBucketPolicy",
      "s3:DeleteBucketPolicy",
      "s3:PutBucketVersioning",
      "s3:PutEncryptionConfiguration",
      "s3:PutBucketPublicAccessBlock",
    ]

    resources = ["arn:aws:s3:::${var.state_bucket_name}"]
  }

  # A deploy role that can rewrite its own trust policy is not a boundary.
  # This matters more than it looks: the role name shares the platform prefix,
  # so the allow above would otherwise cover it. Deny wins over allow.
  statement {
    sid    = "ProtectItsOwnIdentity"
    effect = "Deny"

    actions = [
      "iam:*OpenIDConnectProvider*",
      "iam:UpdateAssumeRolePolicy",
      "iam:DeleteRole",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:AttachRolePolicy",
    ]

    resources = [
      "arn:aws:iam::${var.account_id}:oidc-provider/token.actions.githubusercontent.com",
      aws_iam_role.deploy.arn,
    ]
  }
}

resource "aws_iam_role_policy" "deploy_infrastructure" {
  name   = "genai-platform"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy_infrastructure.json
}
