#!/usr/bin/env bash
# The local image registry, and the cluster's route to it.
#
# `kind load docker-image` would be one line instead of this file. It would also
# produce an image reference with no registry host and no digest, which is
# exactly what two of the workload rules exist to reject. Running a real
# registry keeps those rules honest: the manifests reference
# localhost:5001/...@sha256:..., the same shape as the ECR reference the
# deployed platform uses, and the same rules pass for the same reasons.
#
# Usage: registry.sh up | down
set -euo pipefail

NAME="${REGISTRY_NAME:-kind-registry}"
# 5001, not 5000. macOS binds 5000 to the AirPlay Receiver, and it answers
# before the registry does -- an HTTP 403 with "Server: AirTunes" rather than a
# connection refused, so a push looks like a permissions problem with the
# registry. Turning AirPlay off would work too and is not this repository's
# business.
PORT="${REGISTRY_PORT:-5001}"
CLUSTER="${KIND_CLUSTER:-koerber-demo}"

up() {
  if [ "$(podman inspect -f '{{.State.Running}}' "${NAME}" 2>/dev/null || true)" != "true" ]; then
    podman rm -f "${NAME}" >/dev/null 2>&1 || true
    podman run -d --restart=always -p "127.0.0.1:${PORT}:5000" \
      --name "${NAME}" docker.io/library/registry:2 >/dev/null
    echo "registry ${NAME} listening on 127.0.0.1:${PORT}"
  else
    echo "registry ${NAME} already running"
  fi

  # Each kind node needs a hosts.toml telling containerd where the mirror is.
  # The address is the registry's name on the kind network, not localhost: from
  # inside a node container, localhost is the node.
  local dir="/etc/containerd/certs.d/localhost:${PORT}"
  for node in $(kind get nodes --name "${CLUSTER}" 2>/dev/null); do
    podman exec "${node}" mkdir -p "${dir}"
    podman exec -i "${node}" cp /dev/stdin "${dir}/hosts.toml" <<EOF
[host."http://${NAME}:5000"]
  capabilities = ["pull", "resolve"]
EOF
  done

  # The registry has to share the kind network or the nodes cannot resolve it.
  if ! podman network inspect kind 2>/dev/null | grep -q "\"${NAME}\""; then
    podman network connect kind "${NAME}" 2>/dev/null || true
  fi

  # Advertise the registry to anything in-cluster that wants to find it, which
  # is the convention kind documents rather than something this repo invented.
  kubectl --context "kind-${CLUSTER}" apply -f - <<EOF >/dev/null
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${PORT}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF
  echo "cluster ${CLUSTER} points at localhost:${PORT}"
}

down() {
  podman rm -f "${NAME}" >/dev/null 2>&1 || true
  echo "registry ${NAME} removed"
}

case "${1:-up}" in
  up) up ;;
  down) down ;;
  *) echo "usage: $0 up|down" >&2; exit 2 ;;
esac
