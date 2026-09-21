#!/usr/bin/env bash
#
# Build the corpus index.
#
# Runs as a Job in the cluster rather than on the operator's laptop, for the
# same reason the deployed platform runs it on the jump host: it needs the
# ingestion credentials and a route to the embedding model, and neither belongs
# on a machine that also browses the internet. It also means the operator needs
# no Python environment of their own -- the image already has one.
#
# The credentials here are the admin user's. The mediation service uses
# genai-reader, which can read this index and nothing else. Running the service
# with these credentials would work, and would delete the control that makes
# corpus poisoning impossible rather than unlikely.
#
# Usage: local/ingest.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "${here}/.." && pwd)"

CLUSTER="${KIND_CLUSTER:-koerber-demo}"
CONTEXT="kind-${CLUSTER}"
NS=genai-platform
PORT="${VECTOR_LOCAL_PORT:-9200}"

kubectl() { command kubectl --context "${CONTEXT}" "$@"; }

image="$(kubectl get deploy genai-mediation -n "${NS}" \
  -o jsonpath='{.spec.template.spec.containers[0].image}')"
admin_password="$(kubectl get secret genai-vectors-credentials -n "${NS}" \
  -o jsonpath='{.data.admin_password}' | base64 -d)"
reader_password="$(kubectl get secret genai-vectors-credentials -n "${NS}" \
  -o jsonpath='{.data.reader_password}' | base64 -d)"

########################################
# The read-only role the service authenticates as.
########################################

kubectl port-forward -n "${NS}" svc/genai-vectors "${PORT}:9200" >/dev/null 2>&1 &
forward=$!
trap 'kill ${forward} 2>/dev/null || true' EXIT

until curl -sk -u "admin:${admin_password}" "https://localhost:${PORT}/_cluster/health" >/dev/null 2>&1; do
  sleep 2
done

curl -sk -u "admin:${admin_password}" -X PUT \
  "https://localhost:${PORT}/_plugins/_security/api/roles/genai_reader" \
  -H 'Content-Type: application/json' \
  -d '{"index_permissions":[{"index_patterns":["genai-corpus"],"allowed_actions":["read","indices:admin/mappings/get"]}]}' >/dev/null

curl -sk -u "admin:${admin_password}" -X PUT \
  "https://localhost:${PORT}/_plugins/_security/api/internalusers/genai-reader" \
  -H 'Content-Type: application/json' \
  -d "{\"password\":\"${reader_password}\",\"opendistro_security_roles\":[\"genai_reader\"]}" >/dev/null

echo "read-only user genai-reader can read genai-corpus and nothing else"

kill ${forward} 2>/dev/null || true
trap - EXIT

########################################
# The corpus, and the job that indexes it.
#
# The documents arrive as a ConfigMap rather than being baked into the image.
# In the deployed platform they come from a versioned S3 bucket; either way the
# corpus is data the platform reads, not code it ships, so that a document can
# be changed and re-indexed without rebuilding anything.
########################################

kubectl create configmap genai-corpus -n "${NS}" \
  $(for f in "${repo}"/controls/data/corpus/*.md; do
      [ "$(basename "$f")" = "README.md" ] && continue
      printf -- '--from-file=%s ' "$f"
    done) \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

kubectl delete job genai-ingest -n "${NS}" --ignore-not-found >/dev/null

kubectl apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: genai-ingest
  namespace: ${NS}
  labels:
    app.kubernetes.io/name: genai-ingest
    app.kubernetes.io/part-of: koerber-genai-assistant
spec:
  backoffLimit: 0
  template:
    metadata:
      labels:
        app.kubernetes.io/name: genai-ingest
        app.kubernetes.io/part-of: koerber-genai-assistant
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: ingest
          image: ${image}
          command:
            - python
            - -m
            - mediation.ingest
            - --provider=local
            - --endpoint=https://genai-vectors:9200
            - --source-dir=/corpus
            - --ollama=\$(OLLAMA_ENDPOINT)
            - --strict
            - --recreate
          securityContext:
            allowPrivilegeEscalation: false
            privileged: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            capabilities:
              drop: [ALL]
          resources:
            requests: {cpu: 100m, memory: 128Mi}
            limits: {cpu: "1", memory: 512Mi}
          env:
            - name: OLLAMA_ENDPOINT
              valueFrom:
                configMapKeyRef: {name: genai-local-config, key: ollama_endpoint}
            - name: VECTOR_INGEST_USERNAME
              value: admin
            - name: VECTOR_INGEST_PASSWORD
              valueFrom:
                secretKeyRef: {name: genai-vectors-credentials, key: admin_password}
          volumeMounts:
            - {name: corpus, mountPath: /corpus, readOnly: true}
            - {name: tmp, mountPath: /tmp}
      volumes:
        - name: corpus
          configMap: {name: genai-corpus}
        - name: tmp
          emptyDir: {medium: Memory, sizeLimit: 64Mi}
EOF

echo "indexing"
kubectl wait --for=condition=complete job/genai-ingest -n "${NS}" --timeout=600s >/dev/null 2>&1 &
waiter=$!
kubectl logs -f job/genai-ingest -n "${NS}" 2>/dev/null || true
wait ${waiter} 2>/dev/null || true

kubectl get job genai-ingest -n "${NS}" -o jsonpath='{.status.succeeded}' | grep -q 1 \
  || { echo "ingestion did not complete" >&2; exit 1; }
