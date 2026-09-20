resource "aws_cloudwatch_log_group" "invocations" {
  name              = "/aws/bedrock/${var.name_prefix}/${var.environment}/invocations"
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

resource "aws_bedrock_model_invocation_logging_configuration" "this" {
  logging_config {
    embedding_data_delivery_enabled = true
    text_data_delivery_enabled      = true

    # Image payloads are not delivered: large, rarely useful for detection, and
    # they would widen the confidential surface of the log group.
    image_data_delivery_enabled = false

    cloudwatch_config {
      log_group_name = aws_cloudwatch_log_group.invocations.name
      role_arn       = aws_iam_role.logging.arn
    }
  }
}

resource "aws_iam_role" "logging" {
  name               = "${var.name_prefix}-${var.environment}-bedrock-logging"
  assume_role_policy = data.aws_iam_policy_document.logging_trust.json
}

data "aws_iam_policy_document" "logging_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["bedrock.amazonaws.com"]
    }

    # Pinned to this account, so the role cannot be assumed on behalf of
    # someone else's Bedrock usage.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }
  }
}

resource "aws_iam_role_policy" "logging" {
  name   = "write-invocation-logs"
  role   = aws_iam_role.logging.id
  policy = data.aws_iam_policy_document.logging.json
}

data "aws_iam_policy_document" "logging" {
  statement {
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.invocations.arn}:*"]
  }
}
