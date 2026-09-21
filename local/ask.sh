#!/usr/bin/env bash
#
# Ask one question as a named caller.
#
#   WHO=dana AS_GROUPS=finance-team QUESTION="what is the Q3 revenue forecast?" local/ask.sh
#   WHO=sam                      QUESTION="what is the Q3 revenue forecast?" local/ask.sh
#
# The second is the interesting one. Same question, a caller who is not in
# finance-team, and the restricted passage is not in the answer -- because it
# was never a candidate, not because it was dropped afterwards.
#
# The token is minted inside the mediation pod, which is where PyJWT lives. It
# is deliberately not an endpoint: a service that issues its own identity tokens
# has no authentication, only ceremony.
set -euo pipefail

CLUSTER="${KIND_CLUSTER:-koerber-demo}"
CONTEXT="kind-${CLUSTER}"
NS=genai-platform

WHO="${WHO:-priya}"
# AS_GROUPS, not GROUPS. GROUPS is a bash special variable holding the current
# user's numeric group IDs; bash ignores an assignment to it and keeps its own
# value, so `GROUPS=finance-team` would silently ask as whatever the laptop's
# group list happens to start with. A demo flag that quietly does nothing is
# worse than one that errors.
AS_GROUPS="${AS_GROUPS:-}"
QUESTION="${QUESTION:-What is the parental leave policy?}"

kubectl() { command kubectl --context "${CONTEXT}" "$@"; }

pod="$(kubectl get pod -n "${NS}" -l app.kubernetes.io/name=genai-mediation \
  -o jsonpath='{.items[0].metadata.name}')"

token="$(kubectl exec -n "${NS}" "${pod}" -- \
  python -m mediation.tokens "${WHO}" ${AS_GROUPS:+--groups ${AS_GROUPS}} 2>/dev/null | tr -d '\r\n')"

printf '\n\033[1m%s\033[0m  groups: %s\n' "${WHO}" "${AS_GROUPS:-none beyond all-staff}"
printf '\033[1mQ\033[0m %s\n\n' "${QUESTION}"

body="$(QUESTION="${QUESTION}" python3 -c 'import json,os;print(json.dumps({"question":os.environ["QUESTION"]}))')"

kubectl exec -n "${NS}" "${pod}" -- \
  python -c "
import json, ssl, urllib.request
ctx = ssl._create_unverified_context()
req = urllib.request.Request(
    'https://localhost:8443/ask',
    data=json.dumps(json.loads('''${body}''')).encode(),
    headers={'Content-Type': 'application/json', 'Authorization': 'Bearer ${token}'},
)
try:
    r = json.load(urllib.request.urlopen(req, context=ctx, timeout=300))
except urllib.error.HTTPError as e:
    print('HTTP', e.code, e.read().decode()[:400]); raise SystemExit(1)
print('A', r.get('answer', ''))
srcs = r.get('sources') or []
print()
print('retrieved:', ', '.join(s if isinstance(s, str) else s.get('document','?') for s in srcs) or '(nothing)')
if r.get('guardrail_intervened'):
    print()
    print('** the guardrail intervened **')
"
