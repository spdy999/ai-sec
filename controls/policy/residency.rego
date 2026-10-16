# Control: EU data residency.
#
# Employee prompts and internal documents are confidential and belong to EU data
# subjects. Inference, vector storage and logs must stay in EU regions. A region
# change is a one line diff, which is exactly why it needs a machine gate.
package main

import rego.v1

import data.lib

deny contains msg if {
	lib.provider_region != ""
	not lib.provider_region in lib.eu_regions

	msg := sprintf(
		"residency: provider region %q is outside the EU allow-list %v",
		[lib.provider_region, lib.eu_regions],
	)
}

# Catch a resource that pins a non-EU region in an ARN or service name even when
# the provider itself is configured correctly, for example a VPC endpoint
# pointing at com.amazonaws.us-east-1.bedrock-runtime.
deny contains msg if {
	some resource in lib.typed("aws_vpc_endpoint")
	service_name := object.get(resource, ["values", "service_name"], "")
	service_name != ""

	parts := split(service_name, ".")
	region := parts[2]
	startswith(region, "us-")

	msg := sprintf(
		"residency: VPC endpoint %q targets non-EU service %q",
		[resource.address, service_name],
	)
}
