output "guardrail_id" {
  description = "Guardrail identifier the mediation layer must send on every InvokeModel call."
  value       = aws_bedrock_guardrail.genai.guardrail_id
}

output "guardrail_version" {
  description = "Pinned guardrail version. The proxy must not use DRAFT."
  value       = aws_bedrock_guardrail_version.genai.version
}

output "mediation_role_arn" {
  description = "IRSA role ARN annotated on the mediation service account."
  value       = aws_iam_role.mediation.arn
}

output "kms_key_arn" {
  description = "CMK protecting prompts, documents, vectors and logs."
  value       = aws_kms_key.genai.arn
}

output "rag_bucket" {
  description = "Bucket holding the RAG source corpus."
  value       = aws_s3_bucket.rag_documents.bucket
}

output "vector_collection_endpoint" {
  description = "Private OpenSearch Serverless endpoint for vector search."
  value       = aws_opensearchserverless_collection.vectors.collection_endpoint
}
