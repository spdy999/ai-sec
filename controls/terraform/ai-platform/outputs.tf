output "guardrail_id" {
  description = "Guardrail identifier the mediation layer must send on every InvokeModel call."
  value       = module.guardrail.guardrail_id
}

output "guardrail_version" {
  description = "Pinned guardrail version. The mediation layer must not use DRAFT."
  value       = module.guardrail.guardrail_version
}

output "mediation_role_arn" {
  description = "IRSA role ARN annotated on the mediation service account."
  value       = module.workload_identity.role_arn
}

output "kms_key_arn" {
  description = "CMK protecting prompts, documents, vectors and logs."
  value       = module.encryption.arn
}

output "rag_bucket" {
  description = "Bucket holding the RAG source corpus."
  value       = module.rag_documents.bucket
}

output "vector_collection_endpoint" {
  description = "Private OpenSearch Serverless endpoint for vector search."
  value       = module.vector_store.collection_endpoint
}

output "mediation_log_group_name" {
  description = "Log group the SIEM forwarder subscribes to."
  value       = module.logging.mediation_log_group_name
}
