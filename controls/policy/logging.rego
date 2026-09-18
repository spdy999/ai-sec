# Control: auditability and bounded retention.
#
# Two opposing requirements meet here. Incident response needs a full record of
# what was asked and answered; GDPR data minimisation says that record cannot be
# kept forever. Both are enforced as code.
package main

import rego.v1

import data.lib

max_retention_days := 400

min_retention_days := 30

deny contains msg if {
	some resource in lib.typed("aws_cloudwatch_log_group")
	object.get(resource, ["values", "retention_in_days"], 0) == 0

	msg := sprintf(
		"logging: %s retains logs forever; set retention_in_days for data minimisation",
		[resource.address],
	)
}

deny contains msg if {
	some resource in lib.typed("aws_cloudwatch_log_group")
	retention := object.get(resource, ["values", "retention_in_days"], 0)
	retention > max_retention_days

	msg := sprintf(
		"logging: %s retains logs for %d days, above the %d day maximum",
		[resource.address, retention, max_retention_days],
	)
}

deny contains msg if {
	some resource in lib.typed("aws_cloudwatch_log_group")
	retention := object.get(resource, ["values", "retention_in_days"], 0)
	retention > 0
	retention < min_retention_days

	msg := sprintf(
		"logging: %s retains logs for only %d days, below the %d day minimum for incident investigation",
		[resource.address, retention, min_retention_days],
	)
}

# Bedrock must write an invocation audit trail. Without it there is no record of
# what the model was asked, and no detection source for abuse.
deny contains msg if {
	count(lib.typed("aws_bedrock_guardrail")) > 0
	count(lib.typed("aws_bedrock_model_invocation_logging_configuration")) == 0

	msg := "logging: Bedrock model invocation logging is not configured, leaving no audit trail"
}

deny contains msg if {
	some resource in lib.typed("aws_s3_bucket_versioning")
	object.get(resource, ["values", "versioning_configuration", 0, "status"], "") != "Enabled"

	msg := sprintf(
		"logging: %s has versioning disabled; poisoned RAG documents could not be rolled back",
		[resource.address],
	)
}

deny contains msg if {
	count(lib.typed("aws_s3_bucket")) > 0
	count(lib.typed("aws_s3_bucket_versioning")) == 0

	msg := "logging: RAG bucket has no versioning, so document poisoning is not recoverable"
}
