# Control: no public exposure of AI data or inference paths.
#
# The assistant is internal only. Nothing in this stack should be reachable from
# the internet, and inference traffic should not leave the VPC at all.
package main

import rego.v1

import data.lib

deny contains msg if {
	some resource in lib.typed("aws_s3_bucket_public_access_block")
	some setting in [
		"block_public_acls",
		"block_public_policy",
		"ignore_public_acls",
		"restrict_public_buckets",
	]

	object.get(resource, ["values", setting], false) == false

	msg := sprintf("network: %s has %s disabled", [resource.address, setting])
}

# A bucket with no public access block at all is worse than one with a weak
# block, so check for absence separately.
deny contains msg if {
	count(lib.typed("aws_s3_bucket")) > 0
	count(lib.typed("aws_s3_bucket_public_access_block")) == 0

	msg := "network: buckets are declared with no aws_s3_bucket_public_access_block"
}

deny contains msg if {
	some resource in lib.typed("aws_opensearchserverless_security_policy")
	resource.values.type == "network"

	document := lib.policy_document(resource, "policy")
	some rule in document
	object.get(rule, "AllowFromPublic", false) == true

	msg := sprintf(
		"network: vector store policy %s allows public access; it must be VPC endpoint only",
		[resource.address],
	)
}

# Model traffic must traverse a private endpoint, not the public Bedrock API.
deny contains msg if {
	count(lib.typed("aws_bedrock_guardrail")) > 0

	endpoints := [resource |
		some resource in lib.typed("aws_vpc_endpoint")
		contains(object.get(resource, ["values", "service_name"], ""), "bedrock-runtime")
	]

	count(endpoints) == 0

	msg := "network: Bedrock is used but no bedrock-runtime VPC endpoint is declared"
}

deny contains msg if {
	some resource in lib.typed("aws_vpc_endpoint")
	object.get(resource, ["values", "vpc_endpoint_type"], "") == "Interface"
	object.get(resource, ["values", "private_dns_enabled"], false) == false

	msg := sprintf(
		"network: %s has private DNS disabled, so SDK calls still resolve to the public endpoint",
		[resource.address],
	)
}

# Any security group rule opening the platform to the world.
deny contains msg if {
	some resource in lib.typed("aws_vpc_security_group_ingress_rule")
	object.get(resource, ["values", "cidr_ipv4"], "") == "0.0.0.0/0"

	msg := sprintf("network: %s allows ingress from 0.0.0.0/0", [resource.address])
}
