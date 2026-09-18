# Control: customer-managed encryption everywhere confidential data lands.
#
# AWS-managed keys are not sufficient here. A CMK gives the security team an
# auditable grant list and the ability to revoke access to the RAG corpus and
# the prompt logs independently of the data plane.
package main

import rego.v1

import data.lib

deny contains msg if {
	some resource in lib.typed("aws_s3_bucket_server_side_encryption_configuration")
	some rule in object.get(resource, ["values", "rule"], [])
	some sse in object.get(rule, "apply_server_side_encryption_by_default", [])

	sse.sse_algorithm != "aws:kms"

	msg := sprintf(
		"encryption: %s uses %q; confidential buckets require aws:kms with a CMK",
		[resource.address, sse.sse_algorithm],
	)
}

deny contains msg if {
	some resource in lib.typed("aws_s3_bucket_server_side_encryption_configuration")
	some rule_index, rule in object.get(resource, ["values", "rule"], [])
	some sse_index, sse in object.get(rule, "apply_server_side_encryption_by_default", [])

	sse.sse_algorithm == "aws:kms"
	object.get(sse, "kms_master_key_id", "") == ""
	not lib.unknown_at(
		resource.address,
		["rule", rule_index, "apply_server_side_encryption_by_default", sse_index, "kms_master_key_id"],
	)

	msg := sprintf(
		"encryption: %s sets aws:kms but no kms_master_key_id, so it falls back to the AWS managed key",
		[resource.address],
	)
}

deny contains msg if {
	some resource in lib.typed("aws_cloudwatch_log_group")
	object.get(resource, ["values", "kms_key_id"], null) == null
	not lib.unknown_at(resource.address, ["kms_key_id"])

	msg := sprintf(
		"encryption: log group %s is unencrypted; prompt and response text is confidential",
		[resource.address],
	)
}

deny contains msg if {
	some resource in lib.typed("aws_kms_key")
	object.get(resource, ["values", "enable_key_rotation"], false) == false

	msg := sprintf("encryption: %s does not have automatic key rotation enabled", [resource.address])
}

# The vector store holds embeddings derived from confidential documents, which
# are recoverable enough to be treated as the documents themselves.
deny contains msg if {
	some resource in lib.typed("aws_opensearchserverless_security_policy")
	resource.values.type == "encryption"

	document := lib.policy_document(resource, "policy")
	object.get(document, "AWSOwnedKey", true) == true

	msg := sprintf(
		"encryption: vector store policy %s uses an AWS owned key instead of the platform CMK",
		[resource.address],
	)
}
