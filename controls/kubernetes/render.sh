#!/usr/bin/env bash
#
# Renders the committed manifests against applied Terraform state.
#
# The manifests in base/ carry synthetic identifiers, exactly like the Terraform
# variables do, so the policy gate reads the same shape that gets applied. This
# substitutes the real ones and writes the result to a directory that is never
# committed.
#
# Two things it deliberately does not do: it does not create the identity
# signing key, and it does not create the TLS key pair. Both are Secrets, both
# are made once by an operator, and neither should ever pass through a file in
# the repository. See docs/RUNBOOK.md.
#
# Usage: render.sh [output directory]

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "${here}/../.." && pwd)"
out="${1:-${repo}/.rendered}"

eks="${repo}/controls/terraform/eks-platform"
ai="${repo}/controls/terraform/bedrock-ai"

platform="$(terraform -chdir="${eks}" output -json)"
bedrock="$(terraform -chdir="${ai}" output -json)"

if [ "$(jq -r 'keys | length' <<<"${bedrock}")" -eq 0 ]; then
  echo "bedrock-ai state holds no outputs; apply both layers first" >&2
  exit 1
fi

get() { jq -r ".$1.value" <<<"$2"; }

repository="$(get mediation_repository_url "${platform}")"
role_arn="$(get mediation_role_arn "${bedrock}")"

: "${IMAGE_DIGEST:?set IMAGE_DIGEST to the sha256:... the image build published}"

mkdir -p "${out}"
cp "${here}"/base/*.yaml "${out}/"

# The image is addressed by digest, never by tag. A tag can be repointed after
# review; the ECR repository refuses that, and this refuses to rely on it.
sed -i.bak \
  -e "s|image: .*|image: ${repository}@${IMAGE_DIGEST}|" \
  "${out}/40-deployment.yaml"

sed -i.bak \
  -e "s|eks.amazonaws.com/role-arn: .*|eks.amazonaws.com/role-arn: ${role_arn}|" \
  "${out}/10-serviceaccount.yaml"

python3 - "$out/05-configmap.yaml" <<PY
import pathlib, sys

values = {
    "guardrail_id": "$(get guardrail_id "${bedrock}")",
    "guardrail_version": "$(get guardrail_version "${bedrock}")",
    "chat_model_id": "$(get chat_model_id "${bedrock}")",
    "embedding_model_id": "$(get embedding_model_id "${bedrock}")",
    "vector_collection_endpoint": "$(get vector_collection_endpoint "${bedrock}")",
    "vector_index": "$(get vector_index_name "${bedrock}")",
    "telemetry_log_group": "$(get mediation_log_group_name "${bedrock}")",
}

path = pathlib.Path(sys.argv[1])
lines = []
for line in path.read_text().splitlines():
    key = line.split(":", 1)[0].strip()
    if line.startswith("  ") and key in values:
        lines.append(f'  {key}: "{values[key]}"')
    else:
        lines.append(line)
path.write_text("\n".join(lines) + "\n")
PY

rm -f "${out}"/*.bak

echo "rendered to ${out}:"
sed 's/^/  /' <<<"$(ls "${out}")"
echo
echo "apply with: kubectl --context <ctx> apply -f ${out}"
