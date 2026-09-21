#!/usr/bin/env bash
#
# Bring up the whole local platform: cluster, registry, vector store, guard,
# mediation service.
#
# The deployed platform is provisioned by a pipeline and this is not trying to
# imitate that. What it does keep is the shape of the artefacts: images are
# built once and referenced by digest, secrets are generated here and never
# committed, and the manifests that get applied are the committed ones with
# identifiers substituted -- the same arrangement as controls/kubernetes/render.sh,
# so the policy gate reads what actually runs.
#
# Usage: local/up.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "${here}/.." && pwd)"

CLUSTER="${KIND_CLUSTER:-koerber-demo}"
CONTEXT="kind-${CLUSTER}"
REGISTRY="${REGISTRY_HOST:-localhost:5001}"
NS=genai-platform
OUT="${repo}/.rendered-local"

# The model host, as seen from inside a container on this machine. gvproxy
# forwards it to the macOS host, so Ollama can stay bound to loopback rather
# than being exposed on every interface the laptop has.
MODEL_HOST="${MODEL_HOST:-192.168.127.254}"

kubectl() { command kubectl --context "${CONTEXT}" "$@"; }

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

########################################
step "cluster"
########################################

# Recreate when the cluster is absent, when its node is not running, or when
# it predates the registry mirror. A cluster left over from an earlier session
# looks fine to `kind get clusters` and then fails later with "can only create
# exec sessions on running containers", or silently cannot pull from the
# registry, which is a worse way to find out.
recreate=false
if ! kind get clusters 2>/dev/null | grep -qx "${CLUSTER}"; then
  recreate=true
elif [ "$(podman inspect -f '{{.State.Running}}' "${CLUSTER}-control-plane" 2>/dev/null || echo false)" != "true" ]; then
  echo "cluster ${CLUSTER} exists but its node is not running; recreating"
  recreate=true
elif ! podman exec "${CLUSTER}-control-plane" \
  test -f "/etc/containerd/certs.d/${REGISTRY}/hosts.toml" 2>/dev/null; then
  echo "cluster ${CLUSTER} predates the local registry mirror; recreating"
  recreate=true
fi

if [ "${recreate}" = true ]; then
  kind delete cluster --name "${CLUSTER}" >/dev/null 2>&1 || true
  kind create cluster --config "${here}/kind-cluster.yaml"
else
  echo "cluster ${CLUSTER} already up to date"
fi

########################################
step "registry"
########################################

"${here}/registry.sh" up

########################################
step "images"
########################################

# OpenSearch comes from Docker Hub once and then lives in the local registry.
# Everything the cluster pulls comes from one registry it is configured to
# trust, which is the property the workload policy checks; a manifest pointing
# at docker.io would be refused, correctly.
opensearch_src="docker.io/opensearchproject/opensearch:2.17.1"
opensearch_dst="${REGISTRY}/opensearch:2.17.1"

# The digest comes from the registry, not from the local image store.
#
# `podman image inspect` reports the local manifest digest, which is not always
# what the registry ends up storing -- podman can convert the manifest on the
# way out -- and pulling by the wrong one fails with "not found" from a registry
# that is plainly reachable. `podman push --digestfile` looks like the fix and
# silently writes nothing when the push is a no-op because the layers are
# already there. Asking the registry what it will serve is the only answer that
# cannot drift from what the kubelet will pull.
manifest_digest() {
  curl -sI \
    -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.index.v1+json' \
    "http://${REGISTRY}/v2/$1/manifests/$2" \
    | tr -d '\r' | awk -F': ' '/[Dd]ocker-[Cc]ontent-[Dd]igest/ {print $2}'
}

podman pull -q "${opensearch_src}" >/dev/null
podman tag "${opensearch_src}" "${opensearch_dst}"
podman push --tls-verify=false -q "${opensearch_dst}"
opensearch_digest="$(manifest_digest opensearch 2.17.1)"
echo "opensearch  ${opensearch_digest}"

mediation_dst="${REGISTRY}/genai-mediation:local"
podman build -q -t "${mediation_dst}" -f "${repo}/app/Dockerfile" "${repo}/app" >/dev/null
podman push --tls-verify=false -q "${mediation_dst}"
mediation_digest="$(manifest_digest genai-mediation local)"
echo "mediation   ${mediation_digest}"

for pair in "opensearch ${opensearch_digest}" "mediation ${mediation_digest}"; do
  case "${pair#* }" in
    sha256:*) ;;
    *) echo "could not read the ${pair%% *} digest from ${REGISTRY}; refusing to render an image reference without one" >&2; exit 1 ;;
  esac
done

########################################
step "namespace and secrets"
########################################

kubectl apply -f "${repo}/controls/kubernetes/base/00-namespace.yaml" >/dev/null

# Generated here, held only in the cluster, and generated once.
#
# Created rather than applied, deliberately. OpenSearch reads its admin password
# at first boot and never again; regenerating the Secret on a second bring-up
# would leave the running pod on the old password and every client on the new
# one, which fails as an authentication error and looks like a code bug. The
# passwords change when the cluster is destroyed, which is when the vector
# store forgets them too.
#
# The signing key mints group membership, so anyone holding it is every user at
# once. It has no business in a file in the repository.
if ! kubectl get secret genai-vectors-credentials -n "${NS}" >/dev/null 2>&1; then
  kubectl create secret generic genai-vectors-credentials -n "${NS}" \
    --from-literal=admin_password="$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)Aa1!" \
    --from-literal=reader_username=genai-reader \
    --from-literal=reader_password="$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)Aa1!" \
    >/dev/null
fi

if ! kubectl get secret genai-mediation-identity -n "${NS}" >/dev/null 2>&1; then
  kubectl create secret generic genai-mediation-identity -n "${NS}" \
    --from-literal=signing_key="$(openssl rand -hex 32)" >/dev/null
fi

admin_password="$(kubectl get secret genai-vectors-credentials -n "${NS}" \
  -o jsonpath='{.data.admin_password}' | base64 -d)"

if ! kubectl get secret genai-mediation-tls -n "${NS}" >/dev/null 2>&1; then
  tmp="$(mktemp -d)"
  openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
    -subj "/CN=genai-mediation" \
    -addext "subjectAltName=DNS:genai-mediation,DNS:localhost,IP:127.0.0.1" \
    -keyout "${tmp}/tls.key" -out "${tmp}/tls.crt" >/dev/null 2>&1
  kubectl create secret tls genai-mediation-tls -n "${NS}" \
    --cert="${tmp}/tls.crt" --key="${tmp}/tls.key" >/dev/null
  rm -rf "${tmp}"
fi

kubectl create configmap genai-local-config -n "${NS}" \
  --from-literal=ollama_endpoint="http://${MODEL_HOST}:11434" \
  --from-literal=guard_endpoint="http://genai-guard:8080" \
  --from-literal=guard_model="llama-guard3:1b" \
  --from-literal=chat_model="qwen2.5:3b" \
  --from-literal=embedding_model="nomic-embed-text" \
  --from-literal=vector_endpoint="https://genai-vectors:9200" \
  --from-literal=vector_index="genai-corpus" \
  --from-literal=identity_token_issuer="genai-assistant-local" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

echo "secrets and config written to the cluster only"

########################################
step "manifests"
########################################

rm -rf "${OUT}"
mkdir -p "${OUT}"

auth_header="Basic $(printf 'admin:%s' "${admin_password}" | base64)"

for manifest in "${repo}"/controls/kubernetes/local/*.yaml; do
  sed \
    -e "s|localhost:5001/genai-mediation@sha256:0\{64\}|${REGISTRY}/genai-mediation@${mediation_digest}|g" \
    -e "s|localhost:5001/opensearch@sha256:0\{64\}|${REGISTRY}/opensearch@${opensearch_digest}|g" \
    -e "s|MODEL_HOST_CIDR|${MODEL_HOST}/32|g" \
    -e "s|BASIC_AUTH_HEADER|${auth_header}|g" \
    "${manifest}" > "${OUT}/$(basename "${manifest}")"
done

echo "rendered to ${OUT}"

########################################
step "apply"
########################################

kubectl apply -f "${OUT}/40-networkpolicy.yaml" >/dev/null
kubectl apply -f "${OUT}/10-opensearch.yaml" >/dev/null
kubectl apply -f "${OUT}/20-guard.yaml" >/dev/null
kubectl apply -f "${OUT}/30-mediation.yaml" >/dev/null

echo "waiting for the vector store"
kubectl rollout status deploy/genai-vectors -n "${NS}" --timeout=300s
echo "waiting for the guard"
kubectl rollout status deploy/genai-guard -n "${NS}" --timeout=300s
echo "waiting for mediation"
kubectl rollout status deploy/genai-mediation -n "${NS}" --timeout=300s

printf '\n\033[1mup.\033[0m  next: make local-ingest, then open https://localhost:30443\n'
