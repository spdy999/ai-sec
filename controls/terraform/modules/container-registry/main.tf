# The registry the cluster pulls from.
#
# There is no route to Docker Hub from this VPC, which is the point: the only
# images that can run here are ones that were pushed through this repository,
# scanned on the way in, and are addressable by a digest that cannot be moved
# afterwards.

resource "aws_ecr_repository" "this" {
  name = "${var.name_prefix}-${var.environment}-${var.repository_name}"

  # A mutable tag is a supply chain hole with a friendly name. `:latest` that
  # can be repointed after review means what was reviewed and what runs are
  # different artefacts.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = var.kms_key_arn
  }
}

# Untagged layers accumulate on every rebuild and are billed per GB-month.
resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after a week"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the last ${var.retained_image_count} tagged images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.retained_image_count
        }
        action = { type = "expire" }
      },
    ]
  })
}

# Pull is granted to named principals, not to the account. An identity that can
# reach the ECR endpoint still cannot read this repository unless it is listed.
resource "aws_ecr_repository_policy" "this" {
  repository = aws_ecr_repository.this.name
  policy     = data.aws_iam_policy_document.repository.json
}

data "aws_iam_policy_document" "repository" {
  statement {
    sid    = "PullFromNamedPrincipalsOnly"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = var.pull_principal_arns
    }

    actions = [
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchCheckLayerAvailability",
    ]
  }

  # Unencrypted transport is refused at the resource, not only at the network.
  statement {
    sid    = "TlsOnly"
    effect = "Deny"

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    actions = ["ecr:*"]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}
