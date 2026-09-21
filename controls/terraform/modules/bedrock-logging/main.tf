# The audit trail for model use.
#
# This was `aws_bedrock_model_invocation_logging_configuration` until AWS
# refused the call on this account:
#
#   ValidationException: Your account is not authorized to perform this action.
#   Please create a support case with details about your use case.
#
# The refusal is account-level, not IAM — the same call fails with account
# administrator credentials. CloudTrail replaces it, and for this design it is
# the better instrument anyway:
#
#   * InvokeModel, Converse and their streaming forms are CloudTrail *management*
#     events, recorded by default. Who called, when, which model.
#   * ApplyGuardrail is a CloudTrail *data* event on AWS::Bedrock::Guardrail,
#     and it covers guardrail evaluations performed during model invocation.
#     The event body carries the verdict and which filter produced it.
#
# Neither carries prompt or completion text, which resolves a contradiction the
# old configuration created: it set text_data_delivery_enabled = true, building
# exactly the prompt log that app/mediation/telemetry.py refuses to build.
#
# What is given up is after-the-fact replay of what was asked. That was already
# the deliberate trade in the mediation layer; it is now consistent.

resource "aws_cloudwatch_log_group" "trail" {
  name              = "/aws/cloudtrail/${var.name_prefix}/${var.environment}/bedrock"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
}

# Application-level security telemetry from the mediation layer: guardrail
# blocks, authorization denials, tool calls.
resource "aws_cloudwatch_log_group" "mediation" {
  name              = "/aws/eks/${var.name_prefix}/${var.environment}/mediation"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
}

resource "aws_cloudtrail" "this" {
  name           = "${var.name_prefix}-${var.environment}-bedrock"
  s3_bucket_name = aws_s3_bucket.trail.id
  kms_key_id     = var.kms_key_arn

  # Digest files, so a deleted or altered log file is detectable rather than
  # merely unlikely. An audit trail an attacker can edit is not an audit trail.
  enable_log_file_validation = true

  # Single region. A multi-region trail would collect events from regions
  # outside the EU allow-list into this account's log store, which is the
  # residency boundary this platform exists to hold.
  is_multi_region_trail = false

  # IAM and STS are global and report through us-east-1; without this, the
  # AssumeRoleWithWebIdentity calls that mint the workload's credentials are
  # absent from the trail.
  include_global_service_events = true

  cloud_watch_logs_group_arn = "${aws_cloudwatch_log_group.trail.arn}:*"
  cloud_watch_logs_role_arn  = aws_iam_role.trail.arn

  # Management events cover InvokeModel and Converse. read_write_type ALL keeps
  # read-only calls, which is where reconnaissance shows up.
  advanced_event_selector {
    name = "Model invocation and all other management activity"

    field_selector {
      field  = "eventCategory"
      equals = ["Management"]
    }
  }

  # ApplyGuardrail, including the evaluations Bedrock runs as part of an
  # invocation. This is the record of every block: which filter, what
  # confidence, and whether the guardrail intervened.
  advanced_event_selector {
    name = "Guardrail evaluations"

    field_selector {
      field  = "eventCategory"
      equals = ["Data"]
    }

    field_selector {
      field  = "resources.type"
      equals = ["AWS::Bedrock::Guardrail"]
    }
  }

  # CloudTrail validates it can write to the bucket at creation time, so the
  # policy has to be in place first.
  depends_on = [aws_s3_bucket_policy.trail]
}

resource "aws_s3_bucket" "trail" {
  bucket = "${var.name_prefix}-cloudtrail-${var.environment}-${var.account_id}"

  # Versioning is on below, and CloudTrail writes continuously, so an ordinary
  # destroy leaves non-current versions and delete markers behind and fails with
  # BucketNotEmpty -- taking the rest of the teardown with it, because the AI
  # layer must be destroyed before the cluster it federates with.
  #
  # Off by default. A production audit log store should refuse to be deleted by
  # a terraform destroy; this is set true only for the ephemeral demo
  # environment, which exists to be torn down.
  force_destroy = var.force_destroy_trail_bucket
}

resource "aws_s3_bucket_public_access_block" "trail" {
  bucket = aws_s3_bucket.trail.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "trail" {
  bucket = aws_s3_bucket.trail.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }

    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "trail" {
  bucket = aws_s3_bucket.trail.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "trail" {
  bucket = aws_s3_bucket.trail.id

  rule {
    id     = "expire-trail-objects"
    status = "Enabled"

    filter {}

    expiration {
      days = var.log_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

resource "aws_s3_bucket_policy" "trail" {
  bucket = aws_s3_bucket.trail.id
  policy = data.aws_iam_policy_document.trail_bucket.json
}

data "aws_iam_policy_document" "trail_bucket" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["s3:*"]
    resources = [aws_s3_bucket.trail.arn, "${aws_s3_bucket.trail.arn}/*"]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  # There is deliberately no DenyUnencryptedObjectUploads statement here, unlike
  # the corpus bucket. CloudTrail composes its own PutObject request; a mismatch
  # between the header it sends and the one a deny demands stops log delivery
  # silently, which is a worse outcome than relying on the bucket default and
  # the trail's own kms_key_id. Both are set above.

  statement {
    sid    = "AllowCloudTrailToDescribeTheBucket"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.trail.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = ["arn:aws:cloudtrail:${var.region}:${var.account_id}:trail/${var.name_prefix}-${var.environment}-bedrock"]
    }
  }

  statement {
    sid    = "AllowCloudTrailToDeliverLogs"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.trail.arn}/AWSLogs/${var.account_id}/*"]

    # Scoped to this trail, so another account's trail cannot be pointed at this
    # bucket to poison or pad the log store.
    #
    # AWS documents this statement with a second condition on
    # s3:x-amz-acl = bucket-owner-full-control. Do not add it. Buckets created
    # today default to ObjectOwnership = BucketOwnerEnforced, which disables
    # ACLs, so CloudTrail sends no x-amz-acl header and the condition can never
    # match. The grant then silently does not apply and CreateTrail fails with
    # InsufficientEncryptionPolicyException -- an error that names the bucket
    # and the KMS key and says nothing about ACLs. aws:SourceArn is what scopes
    # this; the ACL condition only ever mattered when ACLs existed.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = ["arn:aws:cloudtrail:${var.region}:${var.account_id}:trail/${var.name_prefix}-${var.environment}-bedrock"]
    }
  }
}

# CloudTrail writes to S3 as itself; delivering the same events to CloudWatch
# Logs, where the SIEM subscribes, is done under an assumed role.
resource "aws_iam_role" "trail" {
  name               = "${var.name_prefix}-${var.environment}-cloudtrail-logs"
  assume_role_policy = data.aws_iam_policy_document.trail_trust.json
}

data "aws_iam_policy_document" "trail_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    # Pinned to this account, so the role cannot be assumed on behalf of someone
    # else's trail.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }
  }
}

resource "aws_iam_role_policy" "trail" {
  name   = "write-trail-events"
  role   = aws_iam_role.trail.id
  policy = data.aws_iam_policy_document.trail_delivery.json
}

data "aws_iam_policy_document" "trail_delivery" {
  statement {
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.trail.arn}:*"]
  }
}
