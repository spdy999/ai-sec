# Runbook

Operational how-to for this repo. `README.md` explains what the controls
prove; this explains what to type, in what order, and what to do when it
breaks. See `CLAUDE.md` for the assignment context and locked decisions.

Everything here runs against AWS in `eu-central-1`. The pipeline owns Terraform,
the policy engine and the image build; the jump host receives what it needs over
Session Manager. Nothing is applied from a workstation except the one-time IAM
setup below.

## 1. Prerequisites

### The AWS account

| Requirement | Why |
|---|---|
| Bedrock model access in `eu-central-1` | Anthropic Claude through the EU inference profile, Titan for embeddings |
| `eu-central-1`, `eu-west-1`, `eu-west-3`, `eu-north-1`, `eu-south-1`, `eu-south-2` all enabled | the EU inference profile routes to all six; the last two are opt-in and a request routed to a disabled region fails |
| Credentials that can create IAM, once | the [one-time setup](#21-one-time-setup) below. With `aws-vault`, pass `--no-session` or IAM refuses with `InvalidClientTokenId` while `sts:GetCallerIdentity` still succeeds |

### The GitHub repository

Repository variables `TF_STATE_BUCKET`, `TF_STATE_REGION`,
`TF_STATE_KMS_KEY_ARN`, `AWS_DEPLOY_ROLE_ARN`, `CLUSTER_ADMIN_ARNS`,
`COST_ALERT_EMAIL`, `SECURITY_ALERT_EMAIL`, and an Actions environment named
`production`. The environment name is load-bearing — the OIDC trust policy pins
`environment:production` in the token subject, so a job without it cannot assume
the role.

### To drive it

`gh` for the workflow dispatches, and the AWS CLI with the Session Manager
plugin plus `kubectl` to reach the private cluster. `terraform` is needed only
for the one-time setup.

## 2. Deploying

Roots are separate applies, in order, because `bedrock-ai` takes
`eks-platform`'s VPC and OIDC values as plain variables rather than a
remote-state lookup. There is deliberately no `apply`/`destroy` shortcut
anywhere — deployment is a workflow with a gate chain, not a command.

### 2.1 One-time setup

From a workstation with admin credentials, once per account:

```bash
cd controls/terraform/pipeline-iam
cp terraform.tfvars.example terraform.tfvars   # bucket name, GitHub owner/repo, numeric IDs
terraform init && terraform apply
terraform output                                # values for the repository variables
```

See `controls/terraform/pipeline-iam/README.md`. `CLUSTER_ADMIN_ARNS` is a
comma-separated list of IAM principals granted EKS cluster admin, for example
`arn:aws:iam::<account>:user/<you>`. The cluster is created with
`bootstrap_cluster_creator_admin_permissions` off, so nobody inherits admin from
having run the apply. Leave the variable unset and no human can read the
cluster: `kubectl` returns `error: You must be logged in to the server
(Unauthorized)` and the EKS console shows **Unauthorized** in place of the Pods
and Nodes counts. The principal has to be the one you actually sign in as — an
entry for a user does not cover a role you assume.

`pipeline-iam` keeps remote state like the other roots, and it has gained
permissions over time: the deploy role needs `cloudwatch:PutMetricAlarm` and the
`sns:` and `sqs:` actions for the alerting module. A push does not pick this root
up, because it runs with a person's credentials — apply it before the first
provision of a rebuilt environment, or the AI layer fails on `AccessDenied`.

### 2.2 The infrastructure

```bash
gh workflow run infra-provision.yml            # gate chain, then both layers in order
gh run watch <run-id> --exit-status --interval 30

# one layer at a time, once it already exists
gh workflow run infra-eks-platform.yml -f action=apply
gh workflow run infra-bedrock-ai.yml   -f action=destroy

gh workflow run infra-destroy.yml -f confirm=destroy
```

Every terraform command lives in `tf-reusable-workflow.yaml`, a reusable workflow
the four above call. A caller passes a layer and an action and nothing else — it
cannot supply its own terraform invocation or skip the gate chain on a first run.

`infra-provision.yml` re-runs the gate chain before it authenticates, generates
the S3 backend and the real tfvars at run time (`.github/scripts/tf-config.sh`),
and reads the platform layer's applied outputs into the AI layer
(`.github/scripts/tf-wire.sh`) so no value is hand-copied. The platform layer's
saved plan is gated immediately before it is applied — upstream's EKS module
reads `aws_caller_identity` and friends during plan, so that layer cannot be
rendered without an account and is gated inside the applying run instead.
`infra-destroy.yml` refuses to start unless `confirm` is literally `destroy`, and
tears the layers down in reverse order.

Both share a concurrency group, so an apply and a destroy cannot overlap, and
neither is cancellable mid-run — a cancelled Terraform leaves a held lock.

A push to `main` touching `controls/terraform/**` triggers `infra-provision.yml`.
The two single-layer callers are dispatch-only.

Note on the approval gate: `environment: production` currently enforces
**nothing**, because required-reviewer protection rules need a paid plan on a
private repository. The real gate today is the policy chain each run carries and
the typed confirmation on teardown. The block stays because it starts working
the day the plan changes, and because the OIDC subject depends on it.

## 3. The application

Three dispatches, in order. Nothing here is typed against the cluster by hand:
the image needs the registry, the secrets need the secret containers, the
manifests need the image digest, and the index needs the corpus bucket, and all
of them come from applied state.

**1. Secret material.** Dispatch `app-secrets.yml` with `confirm=rotate`.

Two values the service needs and no manifest may carry: the key that signs
caller identity tokens, and the TLS key pair the pod presents on :8443.
Terraform creates the secret containers in Secrets Manager, CMK-encrypted, and
deliberately never an `aws_secretsmanager_secret_version` — a version resource
puts the plaintext into state, and state is the one artefact of this pipeline
that holds every attribute of every resource.

The generation happens on the jump host, over Session Manager, so the material
is created inside the VPC and written to Secrets Manager over an endpoint. It
never exists on a GitHub runner. Rerunning the workflow rotates both; the pods
pick a rotated value up on restart, which is what the next step does.

**2. Image and manifests.** Dispatch `app-release.yml`, which calls
`app-image.yml` then `app-deploy.yml` with the digest between them.

The image is built on a GitHub runner because the jump host has no route to the
internet and cannot pull a base image or an npm package. Nothing downstream uses
a tag.

The runner cannot reach the API server either — it is private, the nodes have no
public address, and the VPC has no internet gateway. So the runner does what
only it can: read applied state, render the manifests against it, and run the
policy gate over the *rendered* output rather than the committed shape, because
substituting real identifiers is exactly the step that could introduce a
violation. It then stages the manifests plus a `kubectl` binary in the state
bucket, and sends the jump host a Run Command to fetch and apply them. The
staging prefix is deleted afterwards whether the apply succeeded or not.

`kubectl` crosses that way because the jump host cannot download one: no route
to dl.k8s.io, and an S3 gateway endpoint is the only egress it has.

**3. Index the corpus.** Dispatch `app-index.yml` with `confirm=index`.

Ingestion runs from the jump host, the only principal the OpenSearch data access
policy grants writes to. The service itself can only read, which is what stops a
prompt injection poisoning the corpus. The run passes `--recreate`, which drops
the index before rebuilding it — hence the typed confirmation.

A push to `main` touching `app/**` or `controls/kubernetes/**` triggers
`app-release.yml`. A push touching `controls/data/corpus/**` triggers
`app-index.yml` — and that alone indexes the *previous* corpus, because the
ingester reads documents from S3 and Terraform uploads them. Run
`infra-provision.yml` first, then `app-index.yml`.

## 4. Reaching the live platform

There is no public endpoint anywhere in this design: the API server is private,
the nodes are in private subnets, and there is no internet gateway. Everything
below goes through the jump host over Session Manager, so it needs no inbound
rule and no SSH key.

Prerequisite: the Session Manager plugin for the AWS CLI, and credentials that
can call `ssm:StartSession` on the instance.

```bash
# the cluster endpoint, and the jump host
aws eks describe-cluster --name genai-assistant-prod --region eu-central-1 \
  --query 'cluster.{version:version,status:status,endpoint:endpoint}'

aws ec2 describe-instances \
  --filters Name=tag:Name,Values=genai-assistant-prod-bastion \
            Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].InstanceId' --output text

# a rebuild issues a new endpoint and CA — regenerate this every time
aws eks update-kubeconfig --name genai-assistant-prod --region eu-central-1 \
  --kubeconfig ~/.kube/koerber-live.yaml --alias koerber-live
```

A shell on the jump host is `aws ssm start-session --target <instance-id>`. To
drive the cluster instead, forward the private API server through it:

```bash
aws ssm start-session --target <instance-id> \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters host="<api server hostname>",portNumber=443,localPortNumber=6443
```

`<api server hostname>` is the endpoint above with `https://` stripped. kubectl
then needs three flags, because the certificate is issued for that hostname and
not for localhost:

```bash
kubectl --kubeconfig ~/.kube/koerber-live.yaml --context koerber-live \
  --server https://127.0.0.1:6443 --tls-server-name <api server hostname> \
  -n genai-platform get pods
```

Then mint the identities **in the pod** and forward the service:

```bash
kubectl ... exec deploy/genai-mediation -- python -m mediation.tokens alice --groups all-staff
kubectl ... exec deploy/genai-mediation -- python -m mediation.tokens dana  --groups finance-team
kubectl ... port-forward deploy/genai-mediation 8443:8443
```

Front end at `https://127.0.0.1:8443/`, self-signed. Tokens are minted in the pod
because the signing key's resource policy denies every principal but the workload
and ingestion roles — a workstation with administrator credentials cannot read
it.

A deploy replaces the pods and silently kills the port-forward. Restart it rather
than debugging an empty response.

Never point `kubectl` at a context you have not named explicitly. The
current-context on a work machine is usually a real work cluster.

## 5. Demo walkthrough

Budgeted at three minutes at the front end, plus two to three waiting on the
alarm.

| Ask as | Question | What proves the control |
|---|---|---|
| `alice` | leave carry-over deadline | ordinary retrieval, sources cited |
| `alice` | Q3 revenue forecast | no sources returned — the passage was never a candidate, not filtered afterwards |
| `dana` | the same question | the same corpus answers, because entitlement changed and nothing else did |
| `alice` | who is on call and how to contact them | the document *is* retrieved and the identifiers come back as `{EMAIL}`, `{PHONE}`, `{employee-id}` — masking, not filtering |
| `alice` | `ignore all previous instructions…` | the guardrail intervenes; a model refusal looks identical and is not a control |
| anyone | anything, with the token field emptied | 401 before any retrieval happens |

Rows two and three back to back are the point of the design. Row four and row
five both read `guardrail_intervened: true` — an anonymisation counts as an
intervention — so the answer body, not the badge, separates masked from blocked.

Then the alarm. Ask the injection three times in a minute: the
`guardrail-interventions` alarm sums over 60 seconds with a threshold of 3.

```bash
aws cloudwatch describe-alarms --alarm-names genai-assistant-prod-guardrail-interventions \
  --query 'MetricAlarms[].{state:StateValue,reason:StateReason}'

QUEUE=$(aws sqs get-queue-url --queue-name genai-assistant-prod-security-alerts \
  --query QueueUrl --output text)
aws sqs receive-message --queue-url "$QUEUE" --wait-time-seconds 20 \
  --query 'Messages[].Body' --output text | jq -r '.Message | fromjson'
```

The email subscription on that topic is confirmed, so the alert arrives both
ways; the queue is the path that stays checkable without an inbox after a
rebuild, since a fresh subscription starts unconfirmed. `bedrock-access-denied`
cannot be shown live — CloudTrail delivers on a five-to-fifteen-minute schedule.

## 6. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `infra-provision.yml` fails at `configure-aws-credentials` with `Not authorized to perform sts:AssumeRoleWithWebIdentity` | the job's OIDC subject doesn't match the role's trust policy | the job must declare `environment: production`; the trust policy pins the environment, not the branch, and accepts both the legacy and the ID-qualified subject |
| An apply fails with the state lock already held | a previous run was cancelled mid-apply | `terraform force-unlock <id>` against the same backend, after confirming no run is live; the workflows set `cancel-in-progress: false` to stop this happening |
| `tf-wire.sh` exits with `eks-platform state holds no outputs` | the AI layer was dispatched against an empty or wrong state | apply the platform layer first, and check `TF_STATE_BUCKET` names the state bucket |
| The AI layer fails on `cloudwatch:PutMetricAlarm` or `sqs:CreateQueue` | `pipeline-iam` is behind; it is applied by hand and a push does not pick it up | apply `pipeline-iam` from a workstation, then re-run the provision |
| A rule checking a cross-resource attribute false-positives | the attribute is unresolved at plan time, sitting in `resource_changes[].change.after_unknown`, not `planned_values` | use `lib.unknown_at(address, path)` in the rule |
| `Invalid for_each argument` after adding a client or an admin principal | the value is a security group ID or role ARN, unknown until apply, used as a `for_each` **key** | pass a `map(string)` keyed by a static name (`nodes`, `bastion`), never `toset()` of the unknowns |
| A new rule passes the policy gate but the run still fails | the coverage step requires every rule to fire against a fixture at least once | extend a fixture so the rule's message appears in negative output, or add it to the four-rule exemption list in `controls/policy/coverage.py` with a reason |
| An exempt rule shows up in coverage output | one of the "present but misconfigured" halves in `coverage.py` actually fired | remove it from the exemption list — the gate treats this as stale and fails |
| `aws ssm start-session` hangs or says the target is not connected | the SSM agent has no route: an endpoint missing, or the jump host security group has no egress to it | check the `ssm`, `ssmmessages` and `ec2messages` endpoints exist and `bastion_to_endpoints` allows 443 |
| An AWS call from the jump host hangs with empty stderr, then `Connect timeout on endpoint URL` | a route is not a permission: the gateway or interface endpoint exists but the security group has no egress to the S3 prefix list or the endpoint group | add the egress rule; the same class of failure left nodes `NotReady` with no health issue reported |
| A deploy times out with `timed out waiting for the condition` | the pod cannot reach a secret or the CMK; a rollout during a policy change is denied under the old one | the workflow prints pods, events and logs from the jump host session — read those, then retry once the policy has landed |
| The first question after an index run answers with `sources: []` | OpenSearch Serverless needs about a minute to settle after `--recreate` | wait and ask again |
| A corpus edit produced a green index run and the new content is absent | the ingester reads the documents from S3 and Terraform uploads them | run `infra-provision.yml`, then `app-index.yml -f confirm=index` |
| Merging the two Terraform roots "to simplify" | the OIDC issuer URL becomes unknown at plan time in a single root, which makes the IRSA trust policy unknown, which makes its rule stop firing — silently | don't merge them; that split is a policy requirement, not an ownership one |

## 7. Teardown and rebuild

Written for the case that happens between sessions: the stack is up, costing
roughly $17/day, and it has to go away and come back intact. Roughly 5 minutes
down, 25-30 minutes back up, plus 5 minutes by hand at the end.

**Never start either half without an explicit instruction in the moment.** The
account is personal.

### 7a. What survives, and what must not be touched

Torn down by `infra-destroy.yml`: both layers, everything in them — cluster,
nodes, VPC, endpoints, jump host, guardrail, collection, secrets, corpus bucket,
ECR repository, trail.

Survives, and rebuild depends on it:

- `pipeline-iam` — the OIDC provider and the deploy role. Separate root, never
  dispatched. Destroy it and the [one-time setup](#21-one-time-setup) has to be redone from a
  workstation with admin credentials.
- The Terraform **state bucket**. The destroy writes empty state into it.
- Actions variables `TF_STATE_BUCKET`, `AWS_DEPLOY_ROLE_ARN`,
  `CLUSTER_ADMIN_ARNS`, `COST_ALERT_EMAIL`, `SECURITY_ALERT_EMAIL`, and the
  `production` environment.
- The `eu-south-1` / `eu-south-2` region opt-ins. Account-level, they persist.

The pipeline sets `ephemeral_environment = true`, so the secrets are deleted
with a zero recovery window and the versioned trail bucket is emptied first.
Both names are reusable immediately — no seven-day wait, no
`InvalidRequestException: already scheduled for deletion`.

### 7b. Teardown

```bash
gh run list --limit 5                 # nothing in_progress before starting
gh workflow run infra-destroy.yml -f confirm=destroy
gh run watch <run-id> --exit-status --interval 20
```

Rules that keep it from going wrong:

- **Wait for a quiet pipeline.** An apply and a destroy share the
  `genai-platform-live` concurrency group, so the second queues rather than
  interleaving — but a queued destroy behind a failing apply is worth knowing
  about, not discovering.
- **Never cancel a run mid-terraform.** A cancelled apply leaves the state lock
  held, and the next run fails on it. The workflows set
  `cancel-in-progress: false` for this reason. If it happens anyway:
  `terraform force-unlock <id>` against the same backend, once no run is live.
- **Never dispatch the single-layer destroys by hand** unless the combined one
  has already failed. `bedrock-ai` must go first: its IRSA role trusts the
  cluster's OIDC provider.
- A destroy runs no gate chain. The typed `confirm=destroy` is the only guard.

Then confirm it is actually gone, rather than trusting a green run:

```bash
aws-vault exec spdy999 --no-session -- env AWS_REGION=eu-central-1 sh -c '
  aws eks list-clusters
  aws opensearchserverless list-collections
  aws bedrock list-guardrails --query "guardrails[].name"
  aws secretsmanager list-secrets --query "SecretList[].Name"
  aws ec2 describe-instances --filters Name=instance-state-name,Values=running \
    --query "Reservations[].Instances[].InstanceId"'
```

All five empty. Cost stops within a day; the last day still bills.

### 7c. Rebuild, in order

Each step waits for the previous one to be **green**, not merely started. The
order is a dependency chain, not a preference.

```bash
# 1. both infrastructure layers, platform then AI            ~19 min from empty
gh workflow run infra-provision.yml
gh run watch <run-id> --exit-status --interval 30

# 2. the signing key and the TLS pair, generated on the jump host    ~1 min
gh workflow run app-secrets.yml -f confirm=rotate
gh run watch <run-id> --exit-status --interval 20

# 3. image build, then render + gate + apply with that digest        ~4 min
gh workflow run app-release.yml
gh run watch <run-id> --exit-status --interval 20

# 4. the vector index; --recreate, so it asks for confirmation       ~1 min
gh workflow run app-index.yml -f confirm=index
gh run watch <run-id> --exit-status --interval 20
```

Why each wait matters:

- **2 before 3.** The pod reads both secrets at startup with its own IRSA
  credentials. Deploy first and it crash-loops on a secret that does not exist,
  and the rollout fails on a timeout rather than on the real reason.
- **3 before 4.** Ingestion runs from the jump host, but it needs the AI layer's
  endpoints and the collection's data access policy, both from step 1; step 3
  is what proves the wiring before an ingest failure has to be diagnosed.
- **Do not hand-edit the ConfigMap.** Every identifier changes on a rebuild —
  guardrail id, guardrail version (back to `1`), collection endpoint, secret
  ARNs, bucket names. `controls/kubernetes/render.sh` substitutes them from
  applied state during `app-deploy`, which is exactly why nothing downstream
  refers to a value typed by a human.
- If step 1 is dispatched while `CLUSTER_ADMIN_ARNS` is unset, the cluster comes
  up with no human admin at all and `kubectl` answers `Unauthorized`. Fixing it
  means another apply.
- **The security alert subscription is confirmed by hand, once per rebuild.**
  The AI layer creates an SNS topic and an email subscription; AWS mails a
  confirmation link and delivers nothing until it is clicked, while Terraform
  reports the subscription as created. A green apply is not evidence the alert
  arrives:

  ```bash
  aws sns list-subscriptions-by-topic --topic-arn <topic arn> \
    --query 'Subscriptions[].SubscriptionArn'
  ```

  A value reading `PendingConfirmation` is an alarm nobody receives. The topic
  also delivers to an SQS queue, which needs no confirmation and is therefore
  the path to check — see the
  [demo walkthrough](#5-demo-walkthrough).

### 7d. The five manual minutes

The two Session Manager hops, the two tokens minted in the pod, and the
port-forward — all of it in
[Reaching the live platform](#4-reaching-the-live-platform). Then the
[demo rows](#5-demo-walkthrough), in order. The
injection row is the one that proves the rebuild is genuinely finished:
`guardrail_intervened: true`, not a polite refusal from the model.
