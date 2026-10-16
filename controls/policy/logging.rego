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

# Model use must leave a service-side audit trail. Application telemetry is not
# a substitute: the application is the thing under suspicion, and a compromised
# one simply stops writing. CloudTrail records InvokeModel as a management event
# and ApplyGuardrail as a data event on AWS::Bedrock::Guardrail, which covers
# the guardrail evaluations Bedrock performs during an invocation.
deny contains msg if {
	count(lib.typed("aws_bedrock_guardrail")) > 0
	count(guardrail_audit_trails) == 0

	msg := "logging: no CloudTrail records AWS::Bedrock::Guardrail data events, so guardrail verdicts are unauditable"
}

guardrail_audit_trails contains resource.address if {
	some resource in lib.typed("aws_cloudtrail")
	some selector in object.get(resource, ["values", "advanced_event_selector"], [])
	some field in object.get(selector, "field_selector", [])
	field.field == "resources.type"
	"AWS::Bedrock::Guardrail" in object.get(field, "equals", [])
}

# A trail without digest files records history an attacker can rewrite. Log file
# validation is what makes a deleted or edited log file detectable.
deny contains msg if {
	some resource in lib.typed("aws_cloudtrail")
	object.get(resource, ["values", "enable_log_file_validation"], false) != true

	msg := sprintf(
		"logging: %s has log file validation disabled, so tampering with the audit trail leaves no trace",
		[resource.address],
	)
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

# Recording is not detecting. A trail and a telemetry log group are evidence for
# an investigation somebody has already decided to start; neither raises a hand.
# A platform that runs a model against employee data must have at least one
# alarm that notifies somebody, or every detection in the risk assessment is a
# sentence rather than a control.
deny contains msg if {
	count(lib.typed("aws_bedrock_guardrail")) > 0
	count(notifying_alarms) == 0

	msg := "logging: the platform declares a guardrail but no CloudWatch alarm with a notification action; nothing reads the audit trail"
}

notifying_alarms contains resource.address if {
	some resource in lib.typed("aws_cloudwatch_metric_alarm")
	notifies(resource)
}

# An alarm with no action is a dashboard widget. It changes colour and tells
# nobody, which is worse than absent: it appears in an audit as detection
# coverage.
deny contains msg if {
	some resource in lib.typed("aws_cloudwatch_metric_alarm")
	not notifies(resource)

	msg := sprintf(
		"logging: %s has no alarm_actions, so it changes state and notifies nobody",
		[resource.address],
	)
}

# Terraform renders an empty action list as null rather than as [], so the
# count has to be guarded by is_array or the rule is silently undefined against
# exactly the configuration it exists to catch.
notifies(resource) if {
	actions := object.get(resource, ["values", "alarm_actions"], [])
	is_array(actions)
	count(actions) > 0
}

# An action pointing at a topic created in the same plan is unknown until
# apply, which is not the same as absent. Without this the rule rejects the
# secure layer for having exactly the alarms it asks for.
notifies(resource) if {
	lib.unknown_at(resource.address, ["alarm_actions"])
}
