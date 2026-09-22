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

locals {
  # "eu.anthropic.claude-..." is the profile; the model underneath it is what
  # the approved list holds and what the model ARN names.
  chat_foundation_model_id = join(".", slice(split(".", var.chat_model_id), 1, length(split(".", var.chat_model_id))))
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

    # Three ARN shapes for what is one call. Bedrock serves Anthropic models
    # only through an inference profile, and authorises the request against
    # both the profile and the foundation model in the region it routed to.
    resources = concat(
      [
        for region in var.model_routing_regions :
        "arn:aws:bedrock:${region}::foundation-model/${local.chat_foundation_model_id}"
      ],
      [
        "arn:aws:bedrock:${var.region}:${var.account_id}:inference-profile/${var.chat_model_id}",
      ],
      [
        for model_id in var.approved_model_ids :
        "arn:aws:bedrock:${var.region}::foundation-model/${model_id}"
        if model_id != local.chat_foundation_model_id && model_id != var.embedding_model_id
      ],
    )

    # The ARN, not the id. Bedrock populates bedrock:GuardrailIdentifier with
    # the guardrail's full ARN even when the caller passes the bare id, so a
    # condition written against the id never matches and every guarded call is
    # refused with "no identity-based policy allows the bedrock:InvokeModel
    # action" -- naming the model, saying nothing about the condition that
    # actually failed.
    condition {
      test     = "StringEquals"
      variable = "bedrock:GuardrailIdentifier"
      values   = [var.guardrail_arn]
    }
  }

  # Embedding the question is the one model call a guardrail cannot cover.
  # InvokeModel for an embedding model takes no GuardrailIdentifier, so the
  # statement above -- which requires one -- can never match it, and the call is
  # denied with no hint that a condition was the reason. It is granted here
  # instead, on the embedding model alone: no prompt is generated and no text
  # comes back, only a vector, so there is nothing for a guardrail to filter.
  statement {
    sid       = "EmbedTheQuestion"
    effect    = "Allow"
    actions   = ["bedrock:InvokeModel"]
    resources = ["arn:aws:bedrock:${var.region}::foundation-model/${var.embedding_model_id}"]
  }

  # Used by the guardrail test harness to score an injection corpus without
  # invoking a model.
  # Read at startup, over the VPC endpoint, using the same short-lived IRSA
  # credentials as everything else. No Kubernetes Secret exists to be read out
  # of etcd or printed by anyone holding `kubectl get secret -o yaml`.
  dynamic "statement" {
    for_each = length(var.secret_arns) > 0 ? [1] : []

    content {
      sid       = "ReadOwnSecrets"
      effect    = "Allow"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = var.secret_arns
    }
  }

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

        # Secrets Manager decrypts the secret with this key on the caller's
        # behalf, so GetSecretValue is refused without it -- and the refusal
        # says "Access to KMS is not allowed" with no key id and no action, so
        # it reads as a Secrets Manager problem rather than a missing condition
        # value. The grant above it is necessary and not sufficient.
        "secretsmanager.${var.region}.amazonaws.com",
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
