########################################
# Bedrock AI layer
#
# The AI service itself: the model, the guardrail in front of it, the documents
# it reads, the vectors it searches, and the single identity permitted to touch
# any of them.
#
# Deployed on top of the cluster that ../eks-platform produces, whose outputs
# arrive here as variables.
#
# Read top to bottom, this file is the right half of the architecture diagram.
########################################

module "encryption" {
  source = "../modules/encryption-key"

  alias       = "${var.name_prefix}-${var.environment}"
  description = "CMK for ${var.name_prefix} prompts, documents, vectors and logs"
  account_id  = var.account_id
  region      = var.region
}

# The source corpus: private, CMK-encrypted, TLS-only, versioned so a poisoned
# document can be rolled back and identified.
module "rag_documents" {
  source = "../modules/rag-documents"

  name_prefix = var.name_prefix
  environment = var.environment
  kms_key_arn = module.encryption.arn

  document_source_dir = var.corpus_source_dir
}

# Server-side prompt-attack filtering, PII masking and denied topics. Enforced
# by Bedrock, so it still applies if the mediation service is bypassed.
module "guardrail" {
  source = "../modules/bedrock-guardrail"

  name_prefix = var.name_prefix
  environment = var.environment
  kms_key_arn = module.encryption.arn
}

# Every prompt and response, encrypted, with bounded retention.
module "logging" {
  source = "../modules/bedrock-logging"

  name_prefix        = var.name_prefix
  environment        = var.environment
  account_id         = var.account_id
  kms_key_arn        = module.encryption.arn
  log_retention_days = var.log_retention_days
}

# Private connectivity to Bedrock. The endpoint policy repeats the model
# allow-list, so the network path enforces it as well as IAM.
module "endpoints" {
  source = "../modules/vpc-endpoints"

  name_prefix = var.name_prefix
  environment = var.environment
  region      = var.region

  vpc_id     = var.vpc_id
  subnet_ids = var.private_subnet_ids

  client_security_groups = { nodes = var.eks_node_security_group_id }
  endpoint_az_count      = var.endpoint_az_count
  interface_services     = ["bedrock-runtime"]

  endpoint_policies = {
    "bedrock-runtime" = data.aws_iam_policy_document.bedrock_endpoint.json
  }

  # S3 reaches this VPC through the gateway endpoint the eks-platform layer owns.
  gateway_route_table_ids = []
}

# IAM answers "may this role do this?". The endpoint policy answers "may this be
# done through this network path?". A compromised pod that acquired a broader
# IAM policy still cannot reach an unapproved model from inside this VPC.
data "aws_iam_policy_document" "bedrock_endpoint" {
  statement {
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = [module.workload_identity.role_arn]
    }

    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
      "bedrock:ApplyGuardrail",
    ]

    resources = concat(
      [
        for model_id in var.approved_model_ids :
        "arn:aws:bedrock:${var.region}::foundation-model/${model_id}"
      ],
      [module.guardrail.guardrail_arn],
    )
  }
}

# Embeddings of the corpus. A copy of the data, secured like the data.
module "vector_store" {
  source = "../modules/vector-store"

  name_prefix = var.name_prefix
  environment = var.environment
  kms_key_arn = module.encryption.arn

  vpc_id             = var.vpc_id
  subnet_ids         = slice(var.private_subnet_ids, 0, var.endpoint_az_count)
  security_group_ids = [module.endpoints.security_group_id]

  standby_replicas = var.vector_store_standby_replicas
}

# The only identity with access to any of the above. No static credentials:
# the pod exchanges a projected service account token for short-lived ones.
module "workload_identity" {
  source = "../modules/workload-identity"

  name_prefix = var.name_prefix
  environment = var.environment
  region      = var.region

  oidc_provider_arn    = var.eks_oidc_provider_arn
  oidc_provider_url    = var.eks_oidc_provider_url
  service_namespace    = var.service_namespace
  service_account_name = var.service_account_name

  approved_model_ids = var.approved_model_ids
  guardrail_id       = module.guardrail.guardrail_id
  guardrail_arn      = module.guardrail.guardrail_arn

  rag_bucket_arn          = module.rag_documents.arn
  vector_collection_arn   = module.vector_store.arn
  telemetry_log_group_arn = module.logging.mediation_log_group_arn
  kms_key_arn             = module.encryption.arn
}

########################################
# Vector store access
#
# `aoss:APIAccessAll` in IAM is necessary and not sufficient. OpenSearch
# Serverless refuses every request that is not also granted by a data access
# policy, so an IAM-only grant returns 403 on the first query and nothing in the
# IAM policy explains why.
#
# The split matters more than the mechanics. The service that answers questions
# can read the index and nothing else; only the jump host can create or write
# one. A prompt injection that reaches the retrieval path therefore cannot
# poison the corpus, because the identity running it has no write permission to
# poison it with.
########################################

resource "aws_opensearchserverless_access_policy" "vectors" {
  name = "${var.name_prefix}-vectors-${var.environment}"
  type = "data"

  policy = jsonencode([
    {
      Description = "The mediation service reads the corpus index"
      Rules = [
        {
          ResourceType = "index"
          Resource     = ["index/${module.vector_store.collection_name}/${var.index_name}"]
          Permission   = ["aoss:ReadDocument", "aoss:DescribeIndex"]
        },
      ]
      Principal = [module.workload_identity.role_arn]
    },
    {
      Description = "The operator jump host builds and refreshes it"
      Rules = [
        {
          ResourceType = "index"
          Resource     = ["index/${module.vector_store.collection_name}/${var.index_name}"]
          Permission = [
            "aoss:CreateIndex",
            "aoss:DeleteIndex",
            "aoss:UpdateIndex",
            "aoss:DescribeIndex",
            "aoss:ReadDocument",
            "aoss:WriteDocument",
          ]
        },
        {
          ResourceType = "collection"
          Resource     = ["collection/${module.vector_store.collection_name}"]
          Permission   = ["aoss:CreateCollectionItems", "aoss:DescribeCollectionItems"]
        },
      ]
      Principal = [var.ingestion_role_arn]
    },
  ])
}

########################################
# Ingestion permissions
#
# Attached to the jump host role rather than baked into the platform layer,
# because these are permissions over resources this layer owns: the corpus
# bucket, the embedding model, the collection and the key.
########################################

resource "aws_iam_policy" "ingestion" {
  name   = "${var.name_prefix}-${var.environment}-ingestion"
  policy = data.aws_iam_policy_document.ingestion.json
}

resource "aws_iam_role_policy_attachment" "ingestion" {
  role       = var.ingestion_role_name
  policy_arn = aws_iam_policy.ingestion.arn
}

data "aws_iam_policy_document" "ingestion" {
  statement {
    sid       = "ReadTheCorpus"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = [module.rag_documents.arn, "${module.rag_documents.arn}/*"]
  }

  # Embeddings only. The ingester has no reason to reach a text model, and the
  # condition means it cannot invoke one even by accident.
  statement {
    sid       = "EmbedWithTheApprovedEmbeddingModel"
    effect    = "Allow"
    actions   = ["bedrock:InvokeModel"]
    resources = ["arn:aws:bedrock:${var.region}::foundation-model/${var.embedding_model_id}"]
  }

  statement {
    sid       = "WriteVectors"
    effect    = "Allow"
    actions   = ["aoss:APIAccessAll"]
    resources = [module.vector_store.arn]
  }

  statement {
    sid       = "UseDataKey"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
    resources = [module.encryption.arn]
  }
}
