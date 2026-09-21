#!/usr/bin/env bash
#
# Tear the local platform down.
#
# Deliberately narrow: it removes the cluster this repository created and the
# registry it created, and nothing else. It does not prune images, volumes or
# stopped containers -- those belong to whoever is using this machine, and a
# teardown script that tidies up other people's state is a teardown script
# nobody runs twice.
#
# Usage: local/down.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER="${KIND_CLUSTER:-koerber-demo}"

kind delete cluster --name "${CLUSTER}" 2>/dev/null || true
echo "cluster ${CLUSTER} removed"

"${here}/registry.sh" down
