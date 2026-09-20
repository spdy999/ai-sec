resource "aws_kms_key" "this" {
  description = var.description

  # Annual rotation is the control that bounds how much data a single leaked
  # key version can decrypt.
  enable_key_rotation     = true
  deletion_window_in_days = var.deletion_window_in_days
  multi_region            = false

  policy = data.aws_iam_policy_document.key.json
}

resource "aws_kms_alias" "this" {
  name          = "alias/${var.alias}"
  target_key_id = aws_kms_key.this.key_id
}

data "aws_iam_policy_document" "key" {
  # The account root retains administrative control, which is also what lets
  # IAM policies on consuming roles grant use of this key.
  statement {
    sid       = "EnableRootAccountKeyAdministration"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.account_id}:root"]
    }
  }

  # CloudWatch Logs encrypts log groups on our behalf, scoped to log groups in
  # this account and region only.
  dynamic "statement" {
    for_each = var.log_service_access ? [1] : []

    content {
      sid    = "AllowCloudWatchLogsEncryption"
      effect = "Allow"

      actions = [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:ReEncrypt*",
        "kms:GenerateDataKey*",
        "kms:DescribeKey",
      ]

      resources = ["*"]

      principals {
        type        = "Service"
        identifiers = ["logs.${var.region}.amazonaws.com"]
      }

      condition {
        test     = "ArnLike"
        variable = "kms:EncryptionContext:aws:logs:arn"
        values   = ["arn:aws:logs:${var.region}:${var.account_id}:log-group:*"]
      }
    }
  }

  dynamic "statement" {
    for_each = length(var.service_principals) > 0 ? [1] : []

    content {
      sid    = "AllowNamedServicePrincipals"
      effect = "Allow"

      actions = [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:ReEncrypt*",
        "kms:GenerateDataKey*",
        "kms:DescribeKey",
      ]

      resources = ["*"]

      principals {
        type        = "Service"
        identifiers = var.service_principals
      }
    }
  }
}
