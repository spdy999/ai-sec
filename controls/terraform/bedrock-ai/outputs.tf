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

output "vector_index_name" {
  description = "Index the ingester writes and the service reads."
  value       = var.index_name
}

output "embedding_model_id" {
  description = "Embedding model, for the ingester and the query path."
  value       = var.embedding_model_id
}

output "chat_model_id" {
  description = "Answering model."
  value       = var.chat_model_id
}

output "identity_signing_key_secret_arn" {
  description = "Secret the service reads its token signing key from. The value is written out of band; Terraform never sees it."
  value       = module.app_secrets.identity_signing_key_arn
}

output "tls_secret_arn" {
  description = "Secret holding the mediation listener's certificate and private key."
  value       = module.app_secrets.tls_secret_arn
}

output "security_alert_topic_arn" {
  description = "Topic every security alarm publishes to. The email subscription must be confirmed by hand before anything is delivered."
  value       = module.alerting.topic_arn
}

output "security_alarm_names" {
  description = "Deployed alarms, for the runbook and for evidence."
  value       = module.alerting.alarm_names
}
