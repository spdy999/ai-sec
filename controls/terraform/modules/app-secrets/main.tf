########################################
# Application secrets.
#
# Two pieces of material the service needs and nobody may read from a manifest:
# the key that signs caller identity tokens, and the TLS key pair the pod
# presents on :8443.
#
# This module creates the *containers* and nothing else. There is deliberately
# no aws_secretsmanager_secret_version here, because a version resource puts the
# plaintext into Terraform state, and state is the one artefact of this pipeline
# that holds every attribute of every resource. The values are written once,
# out of band, by `make app-secrets` or the deploy workflow. Terraform owns the
# name, the key, the rotation window and who may read it; it never sees the
# secret itself.
########################################

resource "aws_secretsmanager_secret" "identity_signing_key" {
  name        = "${var.name_prefix}/${var.environment}/identity-signing-key"
  description = "HMAC key for caller identity tokens. Anyone holding it can mint any group membership."

  # The customer managed key, not aws/secretsmanager. The default key is
  # account-wide and grants every principal in the account decrypt through the
  # service; a CMK makes the read path auditable and revocable on its own.
  kms_key_id = var.kms_key_arn

  # A destroyed demo environment should not leave a name that cannot be reused
  # for seven days. Real environments keep the window; this is the same
  # ephemeral_environment switch the trail bucket and the registry use.
  recovery_window_in_days = var.ephemeral_environment ? 0 : 30
}

resource "aws_secretsmanager_secret" "tls" {
  name        = "${var.name_prefix}/${var.environment}/mediation-tls"
  description = "Server certificate and private key for the mediation pod's listener."

  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = var.ephemeral_environment ? 0 : 30
}

# Only the workload may read them, and only these two. A resource policy is
# belt-and-braces next to the role's own IAM policy, but it is the half that
# survives someone widening the role: a principal not named here is refused
# even holding secretsmanager:GetSecretValue on "*".
data "aws_iam_policy_document" "workload_only" {
  for_each = local.secrets

  statement {
    sid    = "DenyEveryPrincipalButTheWorkload"
    effect = "Deny"

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["*"]

    condition {
      test     = "StringNotEquals"
      variable = "aws:PrincipalArn"
      values   = var.reader_role_arns
    }
  }
}

resource "aws_secretsmanager_secret_policy" "workload_only" {
  for_each = local.secrets

  secret_arn = each.value
  policy     = data.aws_iam_policy_document.workload_only[each.key].json
}

locals {
  secrets = {
    identity = aws_secretsmanager_secret.identity_signing_key.arn
    tls      = aws_secretsmanager_secret.tls.arn
  }
}
