# Control: the workload manifests.
#
# These rules read Kubernetes YAML directly rather than a Terraform plan, so the
# same gate that rejects insecure infrastructure also rejects an insecure pod.
# A guard on every rule keeps them from firing on plan documents, which have no
# `kind`.
#
# Much of this is what Pod Security admission "restricted" enforces at runtime.
# Checking it here as well is deliberate: the pipeline should refuse the change
# before it reaches a cluster, and the cluster should refuse it again if the
# pipeline was bypassed. Two independent places, one answer.
package main

import rego.v1

is_kubernetes if object.get(input, "kind", "") != ""

# The pod template, wherever it lives.
pod_spec := input.spec if {
	is_kubernetes
	input.kind == "Pod"
}

pod_spec := input.spec.template.spec if {
	is_kubernetes
	input.kind in {"Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "Job"}
}

all_containers := array.concat(
	object.get(pod_spec, "containers", []),
	object.get(pod_spec, "initContainers", []),
)

workload_name := sprintf("%s/%s", [input.kind, object.get(input.metadata, "name", "unnamed")])

# Registries this platform is permitted to pull from. ECR in the deployed
# platform; the local registry beside the kind cluster in the local runtime.
# Both are private and under the same control as the cluster, which is the
# property that matters -- an image the organisation did not put there cannot be
# pulled, whichever runtime is in front of you.
approved_registry_suffixes := [
	".amazonaws.com",
	"localhost:5001",
]

########################################
# Namespace admission
########################################

deny contains msg if {
	is_kubernetes
	input.kind == "Namespace"

	object.get(input, ["metadata", "labels", "pod-security.kubernetes.io/enforce"], "") != "restricted"

	msg := sprintf(
		"k8s: namespace %s does not enforce the restricted Pod Security profile",
		[input.metadata.name],
	)
}

########################################
# Privilege
########################################

deny contains msg if {
	some container in all_containers
	object.get(container, ["securityContext", "privileged"], false) == true

	msg := sprintf("k8s: %s container %q runs privileged", [workload_name, container.name])
}

deny contains msg if {
	some container in all_containers
	object.get(container, ["securityContext", "allowPrivilegeEscalation"], true) == true

	msg := sprintf(
		"k8s: %s container %q permits privilege escalation",
		[workload_name, container.name],
	)
}

deny contains msg if {
	some container in all_containers
	not runs_as_non_root(container)

	msg := sprintf("k8s: %s container %q may run as root", [workload_name, container.name])
}

runs_as_non_root(container) if object.get(container, ["securityContext", "runAsNonRoot"], false) == true

runs_as_non_root(_) if object.get(pod_spec, ["securityContext", "runAsNonRoot"], false) == true

deny contains msg if {
	some container in all_containers
	dropped := {cap | some cap in object.get(container, ["securityContext", "capabilities", "drop"], [])}
	not "ALL" in dropped

	msg := sprintf(
		"k8s: %s container %q does not drop ALL capabilities",
		[workload_name, container.name],
	)
}

deny contains msg if {
	some container in all_containers
	some cap in object.get(container, ["securityContext", "capabilities", "add"], [])

	msg := sprintf(
		"k8s: %s container %q adds capability %q",
		[workload_name, container.name, cap],
	)
}

deny contains msg if {
	some container in all_containers
	object.get(container, ["securityContext", "readOnlyRootFilesystem"], false) == false

	msg := sprintf(
		"k8s: %s container %q has a writable root filesystem",
		[workload_name, container.name],
	)
}

deny contains msg if {
	is_kubernetes
	pod_spec
	not seccomp_configured

	msg := sprintf("k8s: %s does not set a seccomp profile", [workload_name])
}

seccomp_configured if object.get(pod_spec, ["securityContext", "seccompProfile", "type"], "") != ""

seccomp_configured if {
	some container in all_containers
	object.get(container, ["securityContext", "seccompProfile", "type"], "") != ""
}

########################################
# Host boundaries
########################################

deny contains msg if {
	some namespace_field in ["hostNetwork", "hostPID", "hostIPC"]
	object.get(pod_spec, namespace_field, false) == true

	msg := sprintf("k8s: %s sets %s, removing a namespace boundary", [workload_name, namespace_field])
}

deny contains msg if {
	some volume in object.get(pod_spec, "volumes", [])
	object.get(volume, "hostPath", null) != null

	msg := sprintf(
		"k8s: %s mounts hostPath %q from the node",
		[workload_name, object.get(volume, ["hostPath", "path"], "?")],
	)
}

########################################
# Supply chain
########################################

deny contains msg if {
	some container in all_containers
	not contains(container.image, "@sha256:")

	msg := sprintf(
		"k8s: %s container %q uses a mutable tag; images must be digest-pinned",
		[workload_name, container.name],
	)
}

deny contains msg if {
	some container in all_containers
	not image_registry(container.image)

	msg := sprintf(
		"k8s: %s container %q names no registry, so it resolves to Docker Hub",
		[workload_name, container.name],
	)
}

deny contains msg if {
	some container in all_containers
	registry := image_registry(container.image)
	every suffix in approved_registry_suffixes {
		not endswith(registry, suffix)
	}

	msg := sprintf(
		"k8s: %s container %q pulls from %q, which is not the organisation registry",
		[workload_name, container.name, registry],
	)
}

# An image reference only names a registry when its first segment looks like a
# host. Anything else resolves to Docker Hub by default.
#
# This follows the resolution rule a runtime actually uses: the first path
# segment is a registry when it contains a dot or a colon, or is exactly
# "localhost" -- and only when the reference has a path separator at all.
# Checking for a dot alone was wrong in both directions. It missed
# "localhost:5001/x", calling a private registry "no registry", and an earlier
# version that dropped the separator check would have read the tag in
# "nginx:latest" as a hostname.
image_registry(image) := first if {
	contains(image, "/")
	first := split(image, "/")[0]
	host_like(first)
}

host_like(segment) if contains(segment, ".")

host_like(segment) if contains(segment, ":")

host_like("localhost")

########################################
# Resource governance
########################################

deny contains msg if {
	some container in all_containers
	some limit in ["cpu", "memory"]

	object.get(container, ["resources", "limits", limit], "") == ""

	msg := sprintf(
		"k8s: %s container %q declares no %s limit",
		[workload_name, container.name, limit],
	)
}

########################################
# Workload identity
########################################

deny contains msg if {
	is_kubernetes
	pod_spec

	object.get(pod_spec, "serviceAccountName", "default") == "default"

	msg := sprintf(
		"k8s: %s runs as the default service account, which carries no workload identity",
		[workload_name],
	)
}

deny contains msg if {
	is_kubernetes
	pod_spec

	object.get(pod_spec, "automountServiceAccountToken", true) == true

	msg := sprintf(
		"k8s: %s automounts an API token; project one with an explicit audience instead",
		[workload_name],
	)
}

# Every service account must say which identity it carries. A service account
# with no binding is a workload running as nobody, which in practice means it
# either cannot reach anything or is relying on a node role that every other pod
# shares -- and both of those are found at the worst possible moment.
#
# Two annotations satisfy this, because the platform runs in two places.
#
#   eks.amazonaws.com/role-arn     IRSA. The cluster's OIDC issuer is federated
#                                  with IAM, the pod exchanges a projected token
#                                  for short-lived credentials, and the binding
#                                  is enforced by AWS.
#
#   genai.platform/local-identity  The local runtime, which has no federation to
#                                  enforce. This one is a declaration: it names
#                                  the principal the workload authenticates as
#                                  (an OpenSearch user held in a Secret) so that
#                                  reviewing the manifest tells you what the pod
#                                  can reach.
#
# The second is genuinely weaker than the first and is recorded as such in the
# risk assessment. What both rule out is the case this rule exists for: a
# workload running on the default service account, bound to nothing, documented
# nowhere.
service_account_identity_annotations := [
	"eks.amazonaws.com/role-arn",
	"genai.platform/local-identity",
]

deny contains msg if {
	is_kubernetes
	input.kind == "ServiceAccount"

	every annotation in service_account_identity_annotations {
		object.get(input, ["metadata", "annotations", annotation], "") == ""
	}

	msg := sprintf(
		"k8s: service account %s declares no workload identity, by IRSA annotation or otherwise",
		[input.metadata.name],
	)
}

########################################
# RBAC
########################################

deny contains msg if {
	is_kubernetes
	input.kind in {"Role", "ClusterRole"}

	some rule in object.get(input, "rules", [])
	some field in ["verbs", "resources", "apiGroups"]
	"*" in object.get(rule, field, [])

	msg := sprintf(
		"k8s: %s grants %s \"*\"; least privilege requires each one named",
		[workload_name, field],
	)
}

########################################
# Network
########################################

deny contains msg if {
	is_kubernetes
	input.kind == "NetworkPolicy"

	some rule in object.get(input.spec, "egress", [])
	some target in object.get(rule, "to", [])

	object.get(target, ["ipBlock", "cidr"], "") == "0.0.0.0/0"

	msg := sprintf(
		"k8s: %s allows egress to 0.0.0.0/0, restoring the exfiltration path",
		[workload_name],
	)
}
