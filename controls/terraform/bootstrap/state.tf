# Remote state for the two deployable roots.
#
# State is the most sensitive artefact the pipeline produces: it holds every
# attribute of every resource, including ones marked sensitive in the config.
# It gets the same treatment the RAG corpus gets - CMK encryption, versioning,
# no public access - because the repository's own policy rules demand exactly
# that of any bucket, and a bootstrap that exempts itself is not a standard.

resource "aws_kms_key" "state" {
  description             = "Encrypts Terraform state for the GenAI platform"
  enable_key_rotation     = true
  deletion_window_in_days = 7
}

resource "aws_kms_alias" "state" {
  name          = "alias/genai-assistant-tfstate"
  target_key_id = aws_kms_key.state.key_id
}

resource "aws_s3_bucket" "state" {
  bucket = var.state_bucket_name
}

# Versioning is the recovery path for a corrupted or truncated state file, and
# the reason a bad apply is survivable.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Every version of every state file is kept forever unless something expires it.
# Ninety days is long enough to recover from a mistake nobody noticed at the time.
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

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
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_bucket.json
}

data "aws_iam_policy_document" "state_bucket" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}
