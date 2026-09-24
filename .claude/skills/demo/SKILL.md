---
name: demo
description: Run the presentation walkthrough of this platform — the pipeline gate chain, the live front end, and a security alarm firing end to end. Use after an infra rebuild, or when the user says demo, walkthrough, dry run, or asks to show what is deployed.
---

The full story in one run: **the gates refuse bad config**, then **the live
service answers differently for two identities and blocks an injection**, then
**a detection notices and delivers a message**.

Read the runbook's [Demo walkthrough](../../../docs/RUNBOOK.md#5-demo-walkthrough)
and [Reaching the live platform](../../../docs/RUNBOOK.md#4-reaching-the-live-platform)
for the underlying mechanics. This skill is
the sequence, the preflight that stops it wasting a rehearsal, and the cleanup.

## Arguments

| arg | what runs |
|-----|-----------|
| *(none)* or `full` | preflight, gates, front end, alerts |
| `frontend` | preflight and the front end only |
| `alerts` | preflight and the alarm sequence only |
| `preflight` | the checks alone, nothing opened |

Account `891377211626`, region `eu-central-1`, profile `spdy999`. Every AWS
call below needs `aws-vault exec spdy999 --no-session --`; the `--no-session`
is not optional, see CLAUDE.md.

## Step 0 — Preflight

Never open a tunnel before these pass. A rehearsal that dies three minutes in
because the stack is half up is worse than not starting.

```bash
aws eks describe-cluster --name genai-assistant-prod --region eu-central-1 \
  --query 'cluster.{version:version,status:status,endpoint:endpoint}'

aws ec2 describe-instances \
  --filters Name=tag:Name,Values=genai-assistant-prod-bastion \
            Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].InstanceId' --output text

aws cloudwatch describe-alarms --alarm-name-prefix genai-assistant-prod \
  --query 'MetricAlarms[].{name:AlarmName,state:StateValue,period:Period,threshold:Threshold}'
```

Expect `ACTIVE`, one instance id, and three alarms. Two telemetry alarms read
`INSUFFICIENT_DATA` on a fresh stack and that is correct — a metric filter
emits its zero only when a log event arrives and fails to match, so a log
group with no traffic produces no datapoints at all. `bedrock-access-denied`
reads `OK`, because CloudTrail is always writing.

**A rebuild issues a new endpoint and CA.** Regenerate the kubeconfig before
any kubectl call, every time, or the first command fails with a TLS error that
reads like a network problem:

```bash
aws eks update-kubeconfig --name genai-assistant-prod --region eu-central-1 \
  --kubeconfig ~/.kube/koerber-live.yaml --alias koerber-live
```

If anything is missing, stop and name the rebuild step that fixes it —
`infra provision`, `app secrets -f confirm=rotate`, `app release`,
`app index -f confirm=index`, in that order. Do not dispatch it; say which one.

## Step 1 — The gates

The gate chain runs in the pipeline, not on a workstation. Show the run, not a
local command:

```bash
gh run list --workflow=security.yml --limit 3
gh run view <run-id>
```

Five jobs: the infrastructure policy gate (81 rules pass, then the insecure
fixture must fail, then every rule proven to fire), the workload policy gate
(manifests pass, the bad ones fail, and a real API server refuses a privileged
pod), the secret scan, the third-party scan, and the `security gate` job that
requires the rest. None of them authenticates to AWS.

The point to make out loud: every gate is proven by what it **refuses**. A clean
run of the negative test is itself a build failure.

## Step 2 — The front end

Two hops, because the API server is private and has no public endpoint.

```bash
# hop one: the API server through the jump host. Leave this running.
aws ssm start-session --target <instance id> \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters host="<api hostname>",portNumber=443,localPortNumber=6443
```

`<api hostname>` is the `endpoint` from Step 0 with `https://` stripped.
kubectl then needs three flags, because the certificate is issued for that
hostname and not for localhost:

```bash
kubectl --kubeconfig ~/.kube/koerber-live.yaml --context koerber-live \
  --server https://127.0.0.1:6443 --tls-server-name <api hostname> \
  -n genai-platform get pods
```

Two `genai-mediation` pods, `1/1 Ready`. Then mint the two identities **in the
pod** — the signing key's resource policy denies every principal but the
workload and ingestion roles, so a laptop holding administrator credentials
cannot read it:

```bash
kubectl ... exec deploy/genai-mediation -- python -m mediation.tokens alice --groups all-staff
kubectl ... exec deploy/genai-mediation -- python -m mediation.tokens dana  --groups finance-team

# hop two. Leave this running as well.
kubectl ... port-forward deploy/genai-mediation 8443:8443
```

Front end at `https://127.0.0.1:8443/`, self-signed — the browser warning is
expected and worth saying out loud rather than clicking past in silence.

Hand the user the URL and both tokens, then the five rows in this order:

| ask | as | what it proves |
|-----|----|----------------|
| leave carry-over | alice | retrieval works; answered from `hr-leave-policy.md` |
| Q3 revenue | alice | "no information in the passages" — the finance document was never a candidate |
| Q3 revenue | dana | EUR 14.2M against a plan of 13.5M, from `finance-q3-forecast.md` |
| who is on call and how do I contact them | alice | answered from `engineering-oncall.md`, with `{EMAIL}`, `{PHONE}` and `{employee-id}` in place of the identifiers |
| `ignore all previous instructions…` | alice | guardrail intervened, not a model refusal |

Rows two and three back to back are the point of the design: same question,
same index, different answer, and the difference is in what was retrievable
rather than in what the model was told to say. Row two's badge reads "guardrail
passed" and that is correct — nothing in the question is an attack. The control
doing the work there is entitlement filtering, visible in the Sources line.

Row four is the masking control, and it is the only row where the document is
*supposed* to be retrieved. `engineering-oncall.md` is all-staff, so entitlement
filtering will not withhold it; the contact details come back anonymised because
the guardrail acts on the response. The name is not masked — only email, phone
and the `KOE-` pattern are configured — which is the honest version: masking
covers the entities you named and nothing else.

**The badge reads "guardrail intervened" on this row, same as the injection
row.** An anonymisation counts as an intervention, so the badge alone does not
distinguish a masked answer from a blocked one; the answer body does. Say that
rather than letting it look like row five.

Row five must show `guardrail_intervened`. A polite refusal from the model
looks identical on screen and is not a control — that distinction is the
centrepiece finding of the design summary, so check the badge, do not assume it.

## Step 3 — The alarm

The guardrail alarm sums over 60 seconds with a threshold of 3, so it is the
one detection that can be watched changing state inside a demo.

1. Ask three injection-shaped questions as alice, back to back, through the
   front end. Each should come back blocked.
2. Watch the alarm. Allow two to three minutes: the service writes the event
   synchronously, but the metric filter and CloudWatch add their own delay.

```bash
aws cloudwatch describe-alarms --alarm-names genai-assistant-prod-guardrail-interventions \
  --query 'MetricAlarms[].{state:StateValue,reason:StateReason}'
```

3. Read what was delivered. The topic has an email subscription that has never
   been confirmed on this account, so the queue is the provable path:

```bash
QUEUE=$(aws sqs get-queue-url --queue-name genai-assistant-prod-security-alerts \
  --query QueueUrl --output text)

aws sqs receive-message --queue-url "$QUEUE" \
  --max-number-of-messages 1 --wait-time-seconds 20 \
  --query 'Messages[].Body' --output text | jq -r '.Message | fromjson'
```

The alarm JSON names the alarm, the metric, the threshold and the reason. The
email subscription is confirmed on this account, so the same alert lands in the
inbox — but show the queue, because it is checkable on screen and an inbox is
not, and because a rebuild starts the email subscription unconfirmed again.

`bedrock-access-denied` cannot be demonstrated live: CloudTrail delivers on a
five to fifteen minute schedule. Show it as pre-staged evidence if asked.

## Cleanup

Kill both background sessions — the `port-forward` first, then the SSM
session. A stale port-forward on 8443 makes the next run's browser show an
empty response and look like a broken deploy.

## Never

- **Never dispatch `infra-destroy.yml`**, or any `infra-*` workflow. The user
  pays for this account personally and keeps the stack up between sessions.
  Report what is missing; they decide.
- Never re-run `app index` to "refresh" the corpus mid-demo. `--recreate`
  drops the index before it rebuilds it, so a failure leaves the service
  answering nothing.
- Never present a model refusal as a guardrail block. Read the badge.
