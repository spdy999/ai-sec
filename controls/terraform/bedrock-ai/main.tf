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

# Bedrock no longer serves Anthropic models on-demand by bare model ID -- the
# only supported invocation is through a cross-region inference profile, and
# IAM authorises that call against two ARNs: the profile in this account, and
# the foundation model in whichever region the profile routed to. Granting the
# profile alone produces an AccessDenied that names the model ARN, which is a
# confusing way to learn this.
locals {
  # The profile the service names in modelId. Regional, and in this account.
  inference_profile_arn = "arn:aws:bedrock:${var.region}:${var.account_id}:inference-profile/${var.chat_model_id}"

  # The same model, in every region the profile is permitted to route to. Only
  # the chat model is reached this way; the embedding model is called by bare
  # ID and stays in var.region.
  chat_model_arns = [
    for region in var.model_routing_regions :
    "arn:aws:bedrock:${region}::foundation-model/${local.chat_foundation_model_id}"
  ]

  # "eu.anthropic.claude-..." names the profile; "anthropic.claude-..." names
  # the model underneath it, and that is what has to be on the approved list.
  chat_foundation_model_id = join(".", slice(split(".", var.chat_model_id), 1, length(split(".", var.chat_model_id))))

  embedding_model_arn = "arn:aws:bedrock:${var.region}::foundation-model/${var.embedding_model_id}"
}

module "encryption" {
  source = "../modules/encryption-key"

  alias       = "${var.name_prefix}-${var.environment}"
  description = "CMK for ${var.name_prefix} prompts, documents, vectors and logs"
  account_id  = var.account_id
  region      = var.region

  # CloudTrail encrypts its log files with this key. Without the grant the trail
  # is created and delivers nothing.
  service_principals = ["cloudtrail.amazonaws.com"]
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

# Who invoked which model, and every guardrail verdict — encrypted, tamper
# evident, with bounded retention. Deliberately no prompt or response text.
module "logging" {
  source = "../modules/bedrock-logging"

  name_prefix        = var.name_prefix
  environment        = var.environment
  account_id         = var.account_id
  region             = var.region
  kms_key_arn        = module.encryption.arn
  log_retention_days = var.log_retention_days

  force_destroy_trail_bucket = var.ephemeral_environment
}

# Private connectivity to Bedrock. The endpoint policy repeats the model
# allow-list, so the network path enforces it as well as IAM.
module "endpoints" {
  source = "../modules/vpc-endpoints"

  name_prefix = var.name_prefix
  environment = var.environment
  region      = var.region
  component   = "ai"

  vpc_id     = var.vpc_id
  subnet_ids = var.private_subnet_ids

  # The nodes run the service, which reads. The jump host runs ingestion, which
  # writes -- and both paths leave the VPC through this one security group, so
  # admitting the bastion here is what gives the ingester Bedrock for embeddings
  # and the collection for vectors. The collection needs no separate change: its
  # VPC endpoint already carries this group.
  client_security_groups = merge(
    { nodes = var.eks_node_security_group_id },
    var.bastion_security_group_id != "" ? { bastion = var.bastion_security_group_id } : {},
  )
  endpoint_az_count  = var.endpoint_az_count
  interface_services = ["bedrock-runtime"]

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
    sid    = "TheServiceAsksTheApprovedModels"
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
      local.chat_model_arns,
      [
        local.inference_profile_arn,
        local.embedding_model_arn,
        module.guardrail.guardrail_arn,
      ],
    )
  }

  # The ingester embeds the corpus, and it does so from inside this VPC, so the
  # endpoint policy has to name it as well as IAM -- the two are evaluated
  # separately and the refusal says which one denied: "no VPC endpoint policy
  # allows the bedrock:InvokeModel action" is this document, not the role.
  #
  # Embeddings only, and only the one model. It has no grant on the chat model,
  # the inference profile or the guardrail, so the jump host cannot ask a
  # question through the path it uses to index one.
  statement {
    sid    = "TheIngesterEmbedsOnly"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = [var.ingestion_role_arn]
    }

    actions   = ["bedrock:InvokeModel"]
    resources = [local.embedding_model_arn]
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

  approved_model_ids    = var.approved_model_ids
  account_id            = var.account_id
  chat_model_id         = var.chat_model_id
  embedding_model_id    = var.embedding_model_id
  model_routing_regions = var.model_routing_regions
  guardrail_id          = module.guardrail.guardrail_id
  guardrail_arn         = module.guardrail.guardrail_arn

  rag_bucket_arn          = module.rag_documents.arn
  vector_collection_arn   = module.vector_store.arn
  telemetry_log_group_arn = module.logging.mediation_log_group_arn
  kms_key_arn             = module.encryption.arn

  secret_arns = [
    module.app_secrets.identity_signing_key_arn,
    module.app_secrets.tls_secret_arn,
  ]
}

# The signing key and the listener's key pair. Created here, written out of
# band: see the module header for why no version resource exists.
module "app_secrets" {
  source = "../modules/app-secrets"

  name_prefix = var.name_prefix
  environment = var.environment
  kms_key_arn = module.encryption.arn

  # The workload reads them. The jump host writes them, and is named here so a
  # rotation can be verified by reading back what it just wrote.
  reader_role_arns = [
    module.workload_identity.role_arn,
    var.ingestion_role_arn,
  ]

  ephemeral_environment = var.ephemeral_environment
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
    resources = [local.embedding_model_arn]
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

  # The jump host writes the signing key and the listener's key pair, because
  # it is inside the VPC: the material is generated there and put straight into
  # Secrets Manager over an endpoint, so it never crosses a CI runner. Write
  # and describe only -- reading them back is the workload's job, and the
  # secrets' own resource policy enforces that separately.
  statement {
    sid    = "WriteApplicationSecrets"
    effect = "Allow"

    actions = [
      "secretsmanager:PutSecretValue",
      "secretsmanager:DescribeSecret",
    ]

    resources = [
      module.app_secrets.identity_signing_key_arn,
      module.app_secrets.tls_secret_arn,
    ]
  }
}

# Egress on a security group the platform layer owns, written here because the
# group it points at does not exist until this layer applies. Without it the
# ingester resolves the endpoint, sends, and waits for a connect timeout -- the
# same shape of failure the jump host's missing S3 rule produced, and just as
# silent.
resource "aws_vpc_security_group_egress_rule" "bastion_to_ai_endpoints" {
  count = var.bastion_security_group_id != "" ? 1 : 0

  security_group_id = var.bastion_security_group_id
  description       = "HTTPS to the Bedrock and vector store endpoints, for corpus ingestion"

  referenced_security_group_id = module.endpoints.security_group_id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}
