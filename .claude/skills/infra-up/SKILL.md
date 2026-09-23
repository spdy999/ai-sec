---
name: infra-up
description: Bring the whole platform up on AWS from empty — both Terraform layers, then secrets, image, manifests and the vector index, each waited green. Use when the user says bring it up, rebuild, provision, spin it up, or asks for the stack back after a teardown.
---

The rebuild chain from [RUNBOOK §7c](../../../docs/RUNBOOK.md#7c-rebuild-in-order),
driven end to end. Roughly 25-30 minutes of workflow runs, plus five manual
minutes at the end.

**This spends real money.** Account `891377211626`, region `eu-central-1`,
roughly $17/day while it is up — two thirds of it OpenSearch Serverless.
The user pays for it personally. Do not run this skill on your own judgement;
run it when asked.

Every AWS call below needs `aws-vault exec spdy999 --no-session --`. The
`--no-session` is not optional — see CLAUDE.md.

## Step 0 — Preflight

```bash
gh run list --limit 5
```

Nothing `in_progress`. An apply and a destroy share the `genai-platform-live`
concurrency group, so a dispatch behind a live run queues rather than fails —
worth knowing before, not discovering after.

Then confirm the account is actually empty, so this is a rebuild and not a
second copy:

```bash
aws-vault exec spdy999 --no-session -- env AWS_REGION=eu-central-1 sh -c '
  aws eks list-clusters
  aws opensearchserverless list-collections'
```

If a cluster already exists, stop and say so. The user wanted it up; it is up.

Check the repository variables exist, because a missing one fails late and
expensively:

```bash
gh variable list
```

`TF_STATE_BUCKET`, `AWS_DEPLOY_ROLE_ARN`, `CLUSTER_ADMIN_ARNS`,
`COST_ALERT_EMAIL`, `SECURITY_ALERT_EMAIL`. `CLUSTER_ADMIN_ARNS` unset is the
expensive one: the cluster comes up with no human admin, `kubectl` answers
`Unauthorized`, and fixing it costs another apply.

**`pipeline-iam` is not dispatched and must not be.** It runs with a person's
own credentials, a push does not pick it up, and it has gained permissions over
time. If the AI layer later fails on `cloudwatch:PutMetricAlarm`,
`sns:` or `sqs:` `AccessDenied`, that root is stale — the fix is a manual
`terraform apply` in `controls/terraform/pipeline-iam`, not a retry.

## Step 1 — Both infrastructure layers (~19 min)

```bash
gh workflow run infra-provision.yml
gh run list --workflow=infra-provision.yml --limit 1 --json databaseId -q '.[0].databaseId'
gh run watch <run-id> --exit-status --interval 30
```

One workflow, both layers, `eks-platform` then `bedrock-ai` with `needs`
between them. It re-runs the gate chain before it authenticates, generates the
backend and tfvars at run time, and reads the platform layer's outputs into the
AI layer. Do not dispatch the two single-layer callers to save time — they raced
once and the AI layer applied against a platform layer that had not yet
published `bastion_security_group_id`.

**Never cancel a run mid-terraform.** A cancelled apply leaves the state lock
held and the next run fails on it.

## Step 2 — Secret material (~1 min)

```bash
gh workflow run app-secrets.yml -f confirm=rotate
```

`confirm=rotate` is required; a bare dispatch fails with HTTP 422.

Generated on the jump host over Session Manager, so the signing key and the TLS
pair are created inside the VPC and never touch a runner.

**Step 2 before step 3.** The pod reads both at startup with its own IRSA
credentials. Deploy first and it crash-loops on a secret that does not exist,
and the rollout fails on a timeout rather than on the real reason.

## Step 3 — Image, manifests, rollout (~4 min)

```bash
gh workflow run app-release.yml
```

Calls `app-image.yml` then `app-deploy.yml` with the digest between them. The
manifests are rendered from applied state and gated in their *rendered* form,
then staged in the state bucket with a `kubectl` binary and applied by the jump
host.

**Do not hand-edit the ConfigMap.** Every identifier changes on a rebuild —
guardrail id, guardrail version back to `1`, collection endpoint, secret ARNs,
bucket names. `render.sh` substitutes them all.

## Step 4 — Index the corpus (~1 min)

```bash
gh workflow run app-index.yml -f confirm=index
```

`--recreate` drops the index before rebuilding it, hence the typed confirmation.
Expect `indexed 16 passages` from 6 documents. Serverless needs roughly a
minute afterwards before queries return anything — the first question after a
reindex answering `sources: []` is that, not a failure.

## Step 5 — Verify, rather than trusting four green runs

```bash
aws-vault exec spdy999 --no-session -- aws eks describe-cluster \
  --name genai-assistant-prod --region eu-central-1 \
  --query 'cluster.{version:version,status:status}'

aws-vault exec spdy999 --no-session -- aws sns list-subscriptions-by-topic \
  --region eu-central-1 --topic-arn <topic arn> \
  --query 'Subscriptions[].{endpoint:Endpoint,arn:SubscriptionArn}'
```

Cluster `ACTIVE` on 1.36. The SQS subscription confirms itself; the email one
reads `PendingConfirmation` and has never been delivered on this account —
that is known, and the queue is the path the demo checks.

**A rebuild issues a new cluster endpoint and CA**, so the kubeconfig is stale
before any kubectl call:

```bash
aws-vault exec spdy999 --no-session -- aws eks update-kubeconfig \
  --name genai-assistant-prod --region eu-central-1 \
  --kubeconfig ~/.kube/koerber-live.yaml --alias koerber-live
```

## Step 6 — Report

Say what is up, what it costs per day, and what is left by hand: the two
Session Manager hops, the tokens minted in the pod, the port-forward. Those are
in [RUNBOOK §4](../../../docs/RUNBOOK.md#4-reaching-the-live-platform), and
`/demo` drives them.

Then hand over: **the stack is now billing and stays up until the user says
otherwise.**

## Never

- Never start this without being asked in the moment.
- Never dispatch `infra-eks-platform.yml` or `infra-bedrock-ai.yml` here. They
  are dispatch-only for single-layer repair work.
- Never cancel a run mid-terraform.
- Never move to the next step on a run that is merely started. Each wait is a
  dependency, not a preference.
