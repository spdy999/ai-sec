locals {
  collection_name = "${var.name_prefix}-vectors-${var.environment}"
}

resource "aws_opensearchserverless_collection" "this" {
  name = local.collection_name
  type = "VECTORSEARCH"

  # Billing is per OCU-hour whether the collection is queried once or never.
  # The default, ENABLED, provisions four.
  standby_replicas = var.standby_replicas

  # Both security policies must exist before the collection, or it is created
  # with AWS defaults and then corrected, leaving a window where it was public.
  depends_on = [
    aws_opensearchserverless_security_policy.encryption,
    aws_opensearchserverless_security_policy.network,
  ]
}

resource "aws_opensearchserverless_security_policy" "encryption" {
  name = "${var.name_prefix}-vectors-enc-${var.environment}"
  type = "encryption"

  policy = jsonencode({
    Rules = [{
      ResourceType = "collection"
      Resource     = ["collection/${local.collection_name}"]
    }]

    AWSOwnedKey = false
    KmsARN      = var.kms_key_arn
  })
}

resource "aws_opensearchserverless_security_policy" "network" {
  name = "${var.name_prefix}-vectors-net-${var.environment}"
  type = "network"

  policy = jsonencode([{
    Rules = [{
      ResourceType = "collection"
      Resource     = ["collection/${local.collection_name}"]
    }]

    AllowFromPublic = false
    SourceVPCEs     = [aws_opensearchserverless_vpc_endpoint.this.id]
  }])
}

resource "aws_opensearchserverless_vpc_endpoint" "this" {
  name               = "${var.name_prefix}-vectors-${var.environment}"
  vpc_id             = var.vpc_id
  subnet_ids         = var.subnet_ids
  security_group_ids = var.security_group_ids
}
