# Remote state for the two deployable roots.
#
# State is the most sensitive artefact the pipeline produces: it holds every
# attribute of every resource, including ones marked sensitive in the config.
# It gets the same treatment the RAG corpus gets - CMK encryption, versioning,
# no public access - because the repository's own policy rules demand exactly
# that of any bucket, and a root that exempts itself is not a standard.

resource "aws_kms_key" "state" {
  count = var.create_state_bucket ? 1 : 0

  description             = "Encrypts Terraform state for the GenAI platform"
  enable_key_rotation     = true
  deletion_window_in_days = 7
}

resource "aws_kms_alias" "state" {
  count = var.create_state_bucket ? 1 : 0

  name          = "alias/genai-assistant-tfstate"
  target_key_id = aws_kms_key.state[0].key_id
}

resource "aws_s3_bucket" "state" {
  count = var.create_state_bucket ? 1 : 0

  bucket = var.state_bucket_name
}

# Versioning is the recovery path for a corrupted or truncated state file, and
# the reason a bad apply is survivable.
resource "aws_s3_bucket_versioning" "state" {
  count = var.create_state_bucket ? 1 : 0

  bucket = aws_s3_bucket.state[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  count = var.create_state_bucket ? 1 : 0

  bucket = aws_s3_bucket.state[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state[0].arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  count = var.create_state_bucket ? 1 : 0

  bucket = aws_s3_bucket.state[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Every version of every state file is kept forever unless something expires it.
# Ninety days is long enough to recover from a mistake nobody noticed at the time.
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  count = var.create_state_bucket ? 1 : 0

  bucket = aws_s3_bucket.state[0].id

  rule {
    id     = "expire-noncurrent-state"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Refuse any request that is not TLS. The bucket policy is the only place this
# can be enforced; the backend will happily speak plain HTTP if allowed to.
resource "aws_s3_bucket_policy" "state" {
  count = var.create_state_bucket ? 1 : 0

  bucket = aws_s3_bucket.state[0].id
  policy = data.aws_iam_policy_document.state_bucket[0].json
}

data "aws_iam_policy_document" "state_bucket" {
  count = var.create_state_bucket ? 1 : 0

  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]

    resources = [
      local.state_bucket_arn,
      "${local.state_bucket_arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

# The bucket may be one this root created or one that already existed. Both are
# addressed the same way downstream.
locals {
  state_bucket_arn = "arn:aws:s3:::${var.state_bucket_name}"

  # No CMK when the bucket was made elsewhere, unless one is named. The role
  # then gets no kms statement at all rather than an empty one.
  state_kms_key_arns = compact([
    var.create_state_bucket ? aws_kms_key.state[0].arn : var.state_kms_key_arn,
  ])
}
