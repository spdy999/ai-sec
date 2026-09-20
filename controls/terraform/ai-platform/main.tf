########################################
# AI layer
#
# Bedrock, the guardrail, the document corpus, the vector store and the single
# identity permitted to touch them. Owned by the AI platform team, deployed on
# top of the cluster and VPC that ../platform produces.
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

  client_security_group_id = var.eks_node_security_group_id
  interface_services       = ["bedrock-runtime"]

  endpoint_policies = {
    "bedrock-runtime" = data.aws_iam_policy_document.bedrock_endpoint.json
  }

  # S3 reaches this VPC through the gateway endpoint the platform layer owns.
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
  subnet_ids         = var.private_subnet_ids
  security_group_ids = [module.endpoints.security_group_id]
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
