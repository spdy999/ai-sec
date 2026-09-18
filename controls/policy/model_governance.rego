# Control: model governance.
#
# Only models that have been through security and legal review may be invoked.
# The allow-list lives in lib.rego, owned by security, so a team cannot approve
# a new model by editing its own Terraform.
package main

import rego.v1

import data.lib

# Extract the model id from a Bedrock foundation model ARN.
model_id_from_arn(arn) := id if {
	contains(arn, ":foundation-model/")
	id := split(arn, "/")[1]
}

deny contains msg if {
	some resource in lib.typed("aws_iam_policy")
	document := lib.policy_document(resource, "policy")
	some statement in lib.statements(document)

	statement.Effect == "Allow"
	some arn in lib.as_list(statement.Resource)
	id := model_id_from_arn(arn)

	not id in lib.approved_model_ids

	msg := sprintf(
		"model governance: %s grants access to unapproved model %q",
		[resource.address, id],
	)
}

# Granting InvokeModel on every model in the account defeats the allow-list.
deny contains msg if {
	some resource in lib.typed("aws_iam_policy")
	document := lib.policy_document(resource, "policy")
	some statement in lib.statements(document)

	statement.Effect == "Allow"
	some action in lib.as_list(statement.Action)
	startswith(action, "bedrock:InvokeModel")

	some arn in lib.as_list(statement.Resource)
	endswith(arn, ":foundation-model/*")

	msg := sprintf(
		"model governance: %s allows InvokeModel on all foundation models",
		[resource.address],
	)
}

# A guardrail must exist, and the platform must pin a published version rather
# than DRAFT, which is mutable.
deny contains msg if {
	count(lib.typed("aws_bedrock_guardrail")) > 0
	count(lib.typed("aws_bedrock_guardrail_version")) == 0

	msg := "model governance: guardrail is declared but no immutable version is published"
}

deny contains msg if {
	some resource in lib.typed("aws_bedrock_guardrail")
	filters := [filter |
		some policy in object.get(resource, ["values", "content_policy_config"], [])
		some filter in object.get(policy, "filters_config", [])
		filter.type == "PROMPT_ATTACK"
	]

	count(filters) == 0

	msg := sprintf(
		"model governance: guardrail %s has no PROMPT_ATTACK filter",
		[resource.address],
	)
}

deny contains msg if {
	some resource in lib.typed("aws_bedrock_guardrail")
	some policy in object.get(resource, ["values", "content_policy_config"], [])
	some filter in object.get(policy, "filters_config", [])

	filter.type == "PROMPT_ATTACK"
	filter.input_strength != "HIGH"

	msg := sprintf(
		"model governance: guardrail %s sets PROMPT_ATTACK input strength to %q, expected HIGH",
		[resource.address, filter.input_strength],
	)
}
