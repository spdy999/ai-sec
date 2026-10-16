resource "aws_s3_bucket" "this" {
  bucket = "${var.name_prefix}-rag-documents-${var.environment}"
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }

    bucket_key_enabled = true
  }
}

# The rollback path if a poisoned document reaches the corpus.
resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_expiration_days
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id
  policy = data.aws_iam_policy_document.bucket.json
}

data "aws_iam_policy_document" "bucket" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["s3:*"]
    resources = [aws_s3_bucket.this.arn, "${aws_s3_bucket.this.arn}/*"]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  # Default encryption is a default; this makes it a requirement.
  statement {
    sid    = "DenyUnencryptedObjectUploads"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.this.arn}/*"]

    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["aws:kms"]
    }
  }
}

# The corpus itself.
#
# Every document is synthetic and lives in the repository, so what the
# retrieval path is tested against is reviewable rather than whatever someone
# happened to upload by hand. Three of them exist to be refused: one carries
# invented PII, one carries a prompt-injection payload, one baits a denied
# topic.
resource "aws_s3_object" "document" {
  # README.md describes the corpus; it is not part of it. Uploading it would
  # put a document about the test fixtures into the retrieval path.
  for_each = var.document_source_dir == "" ? toset([]) : setsubtract(
    fileset("${path.root}/${var.document_source_dir}", "*.md"),
    ["README.md"],
  )

  bucket = aws_s3_bucket.this.id
  key    = "corpus/${each.value}"
  source = "${path.root}/${var.document_source_dir}/${each.value}"
  etag   = filemd5("${path.root}/${var.document_source_dir}/${each.value}")

  # Inherits the bucket's CMK default. Stated explicitly so a future change to
  # the bucket default cannot silently downgrade the objects.
  server_side_encryption = "aws:kms"
}
