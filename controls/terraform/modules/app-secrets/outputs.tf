output "identity_signing_key_arn" {
  description = "Secret holding the identity token signing key."
  value       = aws_secretsmanager_secret.identity_signing_key.arn
}

output "tls_secret_arn" {
  description = "Secret holding the mediation listener's certificate and key."
  value       = aws_secretsmanager_secret.tls.arn
}
