# Shared helpers for reading a `terraform show -json` plan document.
#
# Note on unknown values: Terraform omits attributes it cannot resolve until
# apply (for example an ARN produced by another resource). Those attributes are
# absent from planned_values rather than null, so every accessor below defaults
# instead of failing. Rules that depend on an unknown value simply do not fire;
# the insecure fixture in controls/terraform/fixtures/insecure uses only static
# values so that every rule can be proven to trigger.
package lib

import rego.v1

# Every resource in the plan, at any module depth.
#
# Terraform nests composed modules arbitrarily deep under
# planned_values.root_module.child_modules. Walking only the first level would
# silently skip every resource inside a nested module, and a rule that inspects
# nothing passes. The walk below matches any object sitting at a
# ".../resources/<index>" path, which is exactly the shape of a planned
# resource and nothing else.
all_resources := [resource |
	walk(object.get(input, ["planned_values", "root_module"], {}), [path, resource])

	count(path) >= 2
	path[count(path) - 2] == "resources"

	is_object(resource)
	object.get(resource, "address", "") != ""
	object.get(resource, "type", "") != ""
]

# Every planned resource of a given Terraform type.
typed(resource_type) := [resource |
	some resource in all_resources
	resource.type == resource_type
]

# Region configured on the aws provider block.
provider_region := object.get(
	input,
	["configuration", "provider_config", "aws", "expressions", "region", "constant_value"],
	"",
)

# EU regions only. Anything outside this set breaks the residency requirement
# for EU employee data processed by the assistant.
eu_regions := {
	"eu-central-1",
	"eu-central-2",
	"eu-west-1",
	"eu-west-2",
	"eu-west-3",
	"eu-north-1",
	"eu-south-1",
	"eu-south-2",
}

# Foundation models the AI governance board has approved for internal use.
# Held here, in the security policy, not in the module it governs.
approved_model_ids := {
	"anthropic.claude-sonnet-4-5-20250929-v1:0",
	"amazon.titan-embed-text-v2:0",
}

# Parse an inline IAM/resource policy document that Terraform rendered as a
# JSON string. Returns undefined when the string is unknown at plan time.
policy_document(resource, attribute) := parsed if {
	raw := object.get(resource, ["values", attribute], "")
	raw != ""
	parsed := json.unmarshal(raw)
}

# IAM policy statements normalise to a list even when a single statement was
# written as a bare object.
statements(document) := result if {
	is_array(document.Statement)
	result := document.Statement
} else := result if {
	is_object(document.Statement)
	result := [document.Statement]
}

# Coerce an IAM field that may be a string or a list of strings into a list.
as_list(value) := value if is_array(value)

as_list(value) := [value] if is_string(value)

# Terraform reports attributes it cannot resolve until apply in the
# after_unknown map of resource_changes, not in planned_values. An attribute
# that is unknown IS being set, it just has no value yet, so rules must treat
# "unknown" as configured rather than as missing. Without this a CMK ARN
# produced by another resource looks identical to no encryption at all.
after_unknown(address) := unknown if {
	some change in object.get(input, "resource_changes", [])
	change.address == address
	unknown := object.get(change, ["change", "after_unknown"], {})
}

unknown_at(address, path) if {
	object.get(after_unknown(address), path, false) == true
}
