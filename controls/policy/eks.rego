# Control: the Kubernetes platform hosting the mediation layer.
#
# The cluster is where a prompt injection becomes a breach or stays an annoyance.
# If the pod can reach the internet, read node credentials, or talk to an
# unaudited API server, every control above it is decoration.
package main

import rego.v1

import data.lib

########################################
# Control plane exposure
########################################

deny contains msg if {
	some resource in lib.typed("aws_eks_cluster")
	some config in object.get(resource, ["values", "vpc_config"], [])

	object.get(config, "endpoint_public_access", true) == true

	msg := sprintf(
		"eks: %s exposes the Kubernetes API to the internet; administrative access must be private",
		[resource.address],
	)
}

deny contains msg if {
	some resource in lib.typed("aws_eks_cluster")
	some config in object.get(resource, ["values", "vpc_config"], [])

	object.get(config, "endpoint_private_access", false) == false

	msg := sprintf("eks: %s has private API access disabled", [resource.address])
}

########################################
# Cluster secrets at rest
########################################

deny contains msg if {
	some resource in lib.typed("aws_eks_cluster")

	count(object.get(resource, ["values", "encryption_config"], [])) == 0

	msg := sprintf(
		"eks: %s has no encryption_config; Kubernetes Secrets would sit base64-encoded in etcd",
		[resource.address],
	)
}

deny contains msg if {
	some resource in lib.typed("aws_eks_cluster")
	some config in object.get(resource, ["values", "encryption_config"], [])

	not "secrets" in object.get(config, "resources", [])

	msg := sprintf("eks: %s does not envelope-encrypt the secrets resource", [resource.address])
}

########################################
# Audit trail
#
# The audit log is the only record of who changed RBAC or read a Secret. It is
# also the source every Kubernetes detection rule reads from.
########################################

required_cluster_logs := {"api", "audit", "authenticator", "controllerManager", "scheduler"}

deny contains msg if {
	some resource in lib.typed("aws_eks_cluster")

	enabled := {log_type | some log_type in object.get(resource, ["values", "enabled_cluster_log_types"], [])}
	missing := required_cluster_logs - enabled
	count(missing) > 0

	msg := sprintf("eks: %s does not ship control plane logs %v", [resource.address, missing])
}

########################################
# Cluster admission
########################################

deny contains msg if {
	some resource in lib.typed("aws_eks_cluster")
	some config in object.get(resource, ["values", "access_config"], [])

	mode := object.get(config, "authentication_mode", "CONFIG_MAP")
	mode != "API"

	msg := sprintf(
		"eks: %s uses authentication_mode %q; the aws-auth ConfigMap grants cluster access with no IAM audit trail",
		[resource.address, mode],
	)
}

deny contains msg if {
	some resource in lib.typed("aws_eks_cluster")
	some config in object.get(resource, ["values", "access_config"], [])

	object.get(config, "bootstrap_cluster_creator_admin_permissions", true) == true

	msg := sprintf(
		"eks: %s grants cluster admin to whoever ran apply; access must be an explicit, reviewed grant",
		[resource.address],
	)
}

########################################
# Node instance metadata
#
# Without IMDSv2 and a hop limit of one, any pod that can make an HTTP request
# can read the node role's credentials, which defeats workload identity entirely.
########################################

deny contains msg if {
	some resource in lib.typed("aws_launch_template")
	some options in object.get(resource, ["values", "metadata_options"], [])

	object.get(options, "http_tokens", "optional") != "required"

	msg := sprintf(
		"eks: %s allows IMDSv1; a pod could read node credentials with a single unauthenticated GET",
		[resource.address],
	)
}

deny contains msg if {
	some resource in lib.typed("aws_launch_template")
	some options in object.get(resource, ["values", "metadata_options"], [])

	object.get(options, "http_put_response_hop_limit", 2) > 1

	msg := sprintf(
		"eks: %s permits a metadata hop limit above 1, so the request survives the container boundary",
		[resource.address],
	)
}

deny contains msg if {
	some resource in lib.typed("aws_launch_template")

	count(object.get(resource, ["values", "metadata_options"], [])) == 0

	msg := sprintf("eks: %s declares no metadata_options, so IMDSv1 remains available", [resource.address])
}

########################################
# Node storage
########################################

deny contains msg if {
	some resource in lib.typed("aws_launch_template")
	some mapping in object.get(resource, ["values", "block_device_mappings"], [])
	some ebs in object.get(mapping, "ebs", [])

	not encrypted_volume(ebs)

	msg := sprintf("eks: %s attaches an unencrypted EBS volume", [resource.address])
}

# Terraform renders this attribute as the string "true" in some provider
# versions and as a boolean in others.
encrypted_volume(ebs) if object.get(ebs, "encrypted", false) == true

encrypted_volume(ebs) if object.get(ebs, "encrypted", "false") == "true"

########################################
# Workload subnets
########################################

deny contains msg if {
	some resource in lib.typed("aws_subnet")

	object.get(resource, ["values", "map_public_ip_on_launch"], false) == true

	msg := sprintf("eks: %s assigns public IPs on launch; workload subnets must be private", [resource.address])
}

########################################
# Egress path
#
# The design has no internet gateway and no NAT gateway on purpose. Every AWS
# API the workload needs is reached through a VPC endpoint. Adding a NAT gateway
# would restore the exfiltration route that this architecture exists to remove.
########################################

deny contains msg if {
	some resource in lib.typed("aws_nat_gateway")

	msg := sprintf(
		"eks: %s creates a NAT gateway; the mediation layer must have no route to the internet",
		[resource.address],
	)
}

deny contains msg if {
	some resource in lib.typed("aws_internet_gateway")

	msg := sprintf(
		"eks: %s attaches an internet gateway to the platform VPC",
		[resource.address],
	)
}

deny contains msg if {
	some resource in lib.typed("aws_vpc_security_group_egress_rule")

	object.get(resource, ["values", "cidr_ipv4"], "") == "0.0.0.0/0"

	msg := sprintf("eks: %s allows unrestricted egress to 0.0.0.0/0", [resource.address])
}

deny contains msg if {
	some resource in lib.typed("aws_route_table")
	some route in object.get(resource, ["values", "route"], [])

	object.get(route, "cidr_block", "") == "0.0.0.0/0"

	msg := sprintf("eks: %s carries a default route out of the VPC", [resource.address])
}

########################################
# Network-layer evidence
########################################

deny contains msg if {
	count(lib.typed("aws_vpc")) > 0
	count(lib.typed("aws_flow_log")) == 0

	msg := "eks: the platform VPC has no flow logs, so refused connections leave no evidence"
}

deny contains msg if {
	some resource in lib.typed("aws_flow_log")

	object.get(resource, ["values", "traffic_type"], "") != "ALL"

	msg := sprintf(
		"eks: %s does not capture ALL traffic; rejected connections are the interesting ones",
		[resource.address],
	)
}
