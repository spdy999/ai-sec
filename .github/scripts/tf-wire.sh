#!/usr/bin/env bash
#
# Feeds the platform layer's real outputs into the AI layer.
#
# The two roots are separate on purpose (see CLAUDE.md: merged, the cluster's
# OIDC issuer URL is unknown at plan time and the rule checking the IRSA trust
# policy stops firing). The cost of that split is that seven values have to
# cross the boundary. They cross here, read from applied state, so there is no
# hand-copied tfvars file to drift.

set -euo pipefail

: "${TF_EKS:?}" "${TF_BEDROCK:?}"

terraform -chdir="${TF_EKS}" init -input=false -no-color >/dev/null

outputs="$(terraform -chdir="${TF_EKS}" output -json)"

# Fail loudly on an empty state. Without this the AI layer would plan against
# the synthetic defaults in variables.tf and apply an IRSA trust policy that
# trusts a cluster which does not exist.
if [ "$(jq -r 'keys | length' <<<"${outputs}")" -eq 0 ]; then
  echo "eks-platform state holds no outputs; apply the platform layer first" >&2
  exit 1
fi

jq -r '
  "vpc_id                     = \"" + .vpc_id.value + "\"",
  "eks_oidc_provider_arn      = \"" + .eks_oidc_provider_arn.value + "\"",
  "eks_oidc_provider_url      = \"" + .eks_oidc_provider_url.value + "\"",
  "eks_node_security_group_id = \"" + .eks_node_security_group_id.value + "\"",
  "bastion_security_group_id  = \"" + .bastion_security_group_id.value + "\"",
  "private_subnet_ids         = " + (.private_subnet_ids.value | tostring),
  "ingestion_role_arn         = \"" + .bastion_role_arn.value + "\"",
  "ingestion_role_name        = \"" + .bastion_role_name.value + "\""
' <<<"${outputs}" > "${TF_BEDROCK}/platform.auto.tfvars"

echo "wired ${TF_BEDROCK} to the applied platform layer:"
sed 's/^/  /' "${TF_BEDROCK}/platform.auto.tfvars"
