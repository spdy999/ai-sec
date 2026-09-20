resource "aws_iam_role" "mediation" {
  name                 = "${var.name_prefix}-${var.environment}-mediation"
  description          = "Assumed by the AI mediation layer pod via IRSA"
  max_session_duration = var.max_session_duration

  assume_role_policy = data.aws_iam_policy_document.trust.json
}

data "aws_iam_policy_document" "trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    # StringEquals, pinned to exactly one service account. StringLike with a
    # wildcard here would let any pod in the cluster assume this role.
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:${var.service_namespace}:${var.service_account_name}"]
    }

    # Without the audience check, a token minted for another audience would be
    # accepted.
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "mediation" {
  # Approved models only, and only with the guardrail attached. An unguarded
  # call to an approved model is denied by IAM.
  statement {
    sid    = "InvokeApprovedModelsWithGuardrailOnly"
    effect = "Allow"

    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
    ]

    resources = [
      for model_id in var.approved_model_ids :
      "arn:aws:bedrock:${var.region}::foundation-model/${model_id}"
    ]

    condition {
      test     = "StringEquals"
      variable = "bedrock:GuardrailIdentifier"
      values   = [var.guardrail_id]
    }
  }

  # Used by the guardrail test harness to score an injection corpus without
  # invoking a model.
  statement {
    sid       = "ApplyGuardrail"
    effect    = "Allow"
    actions   = ["bedrock:ApplyGuardrail"]
    resources = [var.guardrail_arn]
  }

  statement {
    sid       = "ReadRagCorpus"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${var.rag_bucket_arn}/*"]
  }

  statement {
    sid       = "QueryVectorStore"
    effect    = "Allow"
    actions   = ["aoss:APIAccessAll"]
    resources = [var.vector_collection_arn]
  }

  statement {
    sid       = "WriteSecurityTelemetry"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${var.telemetry_log_group_arn}:*"]
  }

  # Key use is granted here rather than in the key policy. The key would
  # otherwise depend on this role, this role's policy depends on the bucket, and
  # the bucket depends on the key.
  statement {
    sid       = "UseDataKeyForEncryptedStores"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
    resources = [var.kms_key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"

      values = [
        "s3.${var.region}.amazonaws.com",
        "bedrock.${var.region}.amazonaws.com",
      ]
    }
  }
}

resource "aws_iam_policy" "mediation" {
  name   = "${var.name_prefix}-${var.environment}-mediation"
  policy = data.aws_iam_policy_document.mediation.json
}

resource "aws_iam_role_policy_attachment" "mediation" {
  role       = aws_iam_role.mediation.name
  policy_arn = aws_iam_policy.mediation.arn
}
