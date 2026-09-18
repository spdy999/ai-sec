# Control: least privilege for AI workload identities.
#
# The mediation layer is the single most valuable target on the platform: it
# holds the only identity that can read the whole RAG corpus and invoke the
# model. A wildcard here converts a prompt injection into an account compromise.
package main

import rego.v1

import data.lib

deny contains msg if {
	some resource in lib.typed("aws_iam_policy")
	document := lib.policy_document(resource, "policy")
	some statement in lib.statements(document)

	statement.Effect == "Allow"
	some action in lib.as_list(statement.Action)
	action == "*"

	msg := sprintf("iam: %s grants Action \"*\"", [resource.address])
}

deny contains msg if {
	some resource in lib.typed("aws_iam_policy")
	document := lib.policy_document(resource, "policy")
	some statement in lib.statements(document)

	statement.Effect == "Allow"
	some resource_arn in lib.as_list(statement.Resource)
	resource_arn == "*"

	msg := sprintf("iam: %s grants Resource \"*\"", [resource.address])
}

# A service-wide wildcard such as "s3:*" is only marginally better than "*".
deny contains msg if {
	some resource in lib.typed("aws_iam_policy")
	document := lib.policy_document(resource, "policy")
	some statement in lib.statements(document)

	statement.Effect == "Allow"
	some action in lib.as_list(statement.Action)
	endswith(action, ":*")

	msg := sprintf("iam: %s grants service wide action %q", [resource.address, action])
}

# IRSA trust policies must pin one namespace and one service account. A
# StringLike on the sub claim lets any pod in the cluster assume the role.
deny contains msg if {
	some resource in lib.typed("aws_iam_role")
	document := lib.policy_document(resource, "assume_role_policy")
	some statement in lib.statements(document)

	statement.Effect == "Allow"
	some operator, conditions in statement.Condition
	operator == "StringLike"

	some claim, value in conditions
	endswith(claim, ":sub")
	contains(concat(",", lib.as_list(value)), "*")

	msg := sprintf(
		"iam: %s trusts service account pattern %v; pin exactly one namespace and service account with StringEquals",
		[resource.address, value],
	)
}

# Human-usable long-lived credentials have no place in an AI platform account.
deny contains msg if {
	some resource in lib.typed("aws_iam_access_key")

	msg := sprintf(
		"iam: %s creates a static access key; use IRSA or OIDC federation instead",
		[resource.address],
	)
}
