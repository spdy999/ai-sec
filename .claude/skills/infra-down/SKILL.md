---
name: infra-down
description: Destroy the whole platform on AWS — both Terraform layers and everything in them — then prove the account is empty. Use only when the user says tear it down, destroy it, or bring it down, in that moment.
---

The teardown from [RUNBOOK §7b](../../../docs/RUNBOOK.md#7b-teardown). Roughly
5 minutes. Reversed by `/infra-up`, in 25-30.

> **Warning: this is irreversible and destroys live infrastructure.** It
> deletes the EKS cluster, its nodes, the VPC and its endpoints, the jump host,
> the Bedrock guardrail, the OpenSearch collection and its vector index, the
> Secrets Manager secrets, the corpus bucket, the ECR repository and the
> CloudTrail trail — in account `891377211626`, region `eu-central-1`.
> The secrets are deleted with a zero recovery window, so there is no undelete.

## Step 0 — Confirm, in this message

**Do not dispatch anything until the user has asked for a teardown in the
message you are answering.** A teardown mentioned earlier in the session, in
the runbook, or implied by "we're done for today" is not an instruction. The
account is personal and the user's standing rule is explicit: *"the tear down i
will tell you myself. dont destroy anything without my command."*

If the instruction is anything less than unambiguous, ask — once, plainly —
and wait.

## Step 1 — Wait for a quiet pipeline

```bash
gh run list --limit 5
```

Nothing `in_progress`. An apply and a destroy share the `genai-platform-live`
concurrency group, so a destroy dispatched behind a live apply queues silently
and runs later, which is worse than refusing now.

## Step 2 — Dispatch

```bash
gh workflow run infra-destroy.yml -f confirm=destroy
gh run list --workflow=infra-destroy.yml --limit 1 --json databaseId -q '.[0].databaseId'
gh run watch <run-id> --exit-status --interval 20
```

`confirm` must be literally `destroy`; the workflow refuses to start otherwise,
and that typed value is the only guard — **a destroy runs no gate chain.**

It tears the layers down in reverse order, `bedrock-ai` first, because the IRSA
role trusts the cluster's OIDC provider.

**Never cancel a run mid-terraform.** A cancelled destroy leaves the state lock
held and the next run fails on it. If it happens anyway, `terraform force-unlock
<id>` against the same backend, once no run is live.

**Never dispatch the single-layer destroys by hand** unless the combined one has
already failed.

## Step 3 — Prove it, rather than trusting a green run

```bash
aws-vault exec spdy999 --no-session -- env AWS_REGION=eu-central-1 sh -c '
  aws eks list-clusters
  aws opensearchserverless list-collections
  aws bedrock list-guardrails --query "guardrails[].name"
  aws secretsmanager list-secrets --query "SecretList[].Name"
  aws ec2 describe-instances --filters Name=instance-state-name,Values=running \
    --query "Reservations[].Instances[].InstanceId"'
```

All five empty. `--no-session` is not optional — see CLAUDE.md.

If anything remains, say which and stop. A half-destroyed stack still bills and
a second destroy on top of a held lock makes it worse.

## Step 4 — Report

What is gone, and what deliberately survives, because the rebuild depends on it:

- `pipeline-iam` — the OIDC provider and the deploy role. Never dispatched.
  Destroy it and the one-time setup has to be redone from a workstation with
  admin credentials.
- The Terraform **state bucket**. The destroy writes empty state into it.
- The Actions variables and the `production` environment.
- The `eu-south-1` / `eu-south-2` region opt-ins — account-level, they persist.

Cost stops within a day; the last day still bills. Say roughly what the session
cost if the user asks, and that `/infra-up` brings it all back.

## Never

- Never run this on your own judgement, at the end of a session, to save money,
  or because the work looks finished.
- Never destroy `pipeline-iam` or the state bucket.
- Never cancel a run mid-terraform.
