# Control: what may become a running container.
#
# The cluster has no route to Docker Hub, so every image it runs arrives through
# one ECR repository. That makes the repository the choke point, and a choke
# point with mutable tags, no scanning or an unauditable key is not a control.
#
# The Kubernetes half of this lives in kubernetes.rego, which refuses a mutable
# tag or an unknown registry on a workload. This half is about the registry
# those workloads pull from.
package main

import rego.v1

import data.lib

deny contains msg if {
	some resource in lib.typed("aws_ecr_repository")

	object.get(resource, ["values", "image_tag_mutability"], "MUTABLE") != "IMMUTABLE"

	msg := sprintf(
		"supply chain: %s allows tags to be moved; the image reviewed and the image running would be different artefacts",
		[resource.address],
	)
}

deny contains msg if {
	some resource in lib.typed("aws_ecr_repository")

	count(object.get(resource, ["values", "image_scanning_configuration"], [])) == 0

	msg := sprintf("supply chain: %s declares no image scanning configuration", [resource.address])
}

deny contains msg if {
	some resource in lib.typed("aws_ecr_repository")
	some config in object.get(resource, ["values", "image_scanning_configuration"], [])

	object.get(config, "scan_on_push", false) == false

	msg := sprintf(
		"supply chain: %s does not scan on push, so a known-vulnerable layer enters the only registry the cluster trusts",
		[resource.address],
	)
}

deny contains msg if {
	some resource in lib.typed("aws_ecr_repository")

	count(object.get(resource, ["values", "encryption_configuration"], [])) == 0

	msg := sprintf(
		"supply chain: %s falls back to an AWS-owned key; image layers must be encrypted under a key this organisation can audit and revoke",
		[resource.address],
	)
}

deny contains msg if {
	some resource in lib.typed("aws_ecr_repository")
	some config in object.get(resource, ["values", "encryption_configuration"], [])

	object.get(config, "encryption_type", "AES256") != "KMS"

	msg := sprintf("supply chain: %s uses %s encryption rather than a customer-managed key", [
		resource.address,
		object.get(config, "encryption_type", "AES256"),
	])
}
