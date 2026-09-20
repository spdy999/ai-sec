#!/usr/bin/env bash
# Prove that default-deny egress is enforced, rather than merely declared.
#
# A NetworkPolicy that is accepted by the API server but ignored by the CNI
# looks identical to one that works. The only way to tell them apart is to send
# a packet, so this sends one before the policy and one after.
#
# This is the control that turns a successful prompt injection into a failed
# one: the model is talked into exfiltrating the corpus, and the connection
# never leaves the pod.
#
# Scaffolding runs in its own namespace. It uses a public image, which the
# admission policies forbid in genai-platform on purpose, so it is deliberately
# kept outside the governed namespace and removed afterwards.
set -euo pipefail

CONTEXT="${CONTEXT:-kind-koerber-demo}"
NS=netpol-proof
KC="kubectl --context ${CONTEXT} -n ${NS}"

cleanup() {
	kubectl --context "${CONTEXT}" delete namespace "${NS}" --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

kubectl --context "${CONTEXT}" create namespace "${NS}" >/dev/null

$KC run server --image=docker.io/library/busybox:1.36 --labels=app=server \
	--command -- sh -c "echo reachable > /tmp/index.html; httpd -f -p 8080 -h /tmp" >/dev/null
$KC run client --image=docker.io/library/busybox:1.36 --labels=app=client \
	--command -- sleep 600 >/dev/null

$KC wait --for=condition=Ready pod/server pod/client --timeout=180s >/dev/null
SERVER_IP=$($KC get pod server -o jsonpath='{.status.podIP}')

echo "=================================================================="
echo " 1. No policy yet. The pod can reach the network."
echo "=================================================================="
echo -n "   client -> ${SERVER_IP}:8080 : "
$KC exec client -- wget -T 3 -q -O- "http://${SERVER_IP}:8080/index.html" || true

echo ""
echo "=================================================================="
echo " 2. Apply default-deny, in both directions, to every pod."
echo "=================================================================="
kubectl --context "${CONTEXT}" apply -f - >/dev/null <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: ${NS}
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
EOF
echo "   applied"
sleep 5

echo ""
echo "=================================================================="
echo " 3. The same request. It must now fail."
echo "=================================================================="
echo -n "   client -> ${SERVER_IP}:8080 : "

if $KC exec client -- wget -T 3 -q -O- "http://${SERVER_IP}:8080/index.html" 2>/dev/null; then
	echo ""
	echo "FAILED: traffic still flowed. The CNI is not enforcing NetworkPolicy,"
	echo "so the default-deny egress control is declared but not effective."
	exit 1
fi

echo "refused"
echo ""
echo "default-deny egress is enforced by the CNI, not merely declared."
