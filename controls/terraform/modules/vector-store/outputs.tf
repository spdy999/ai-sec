output "arn" {
  description = "Collection ARN."
  value       = aws_opensearchserverless_collection.this.arn
}

output "collection_endpoint" {
  description = "Private endpoint used for vector search."
  value       = aws_opensearchserverless_collection.this.collection_endpoint
}
