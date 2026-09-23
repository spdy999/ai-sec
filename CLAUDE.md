# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Implementation artefacts for a take-home assignment: a secure enterprise GenAI
platform (internal RAG assistant) on AWS Bedrock and EKS. The repo holds code
and config only — the written deliverables (design summary, slides, diagrams,
cost analysis) live in the user's Obsidian vault on Google Drive, under
`.../Interview/Jobs/2026/Koerber/Assignment/`.

**Confidential.** Do not publish any of it — no public repos, no Artifacts, no
third-party services. All sample data must be synthetic.

## Working agreement

Propose the shape of structural work and get approval before writing it. Two
rejected refactors came from deciding first and reporting afterwards. Ordinary
implementation inside an already-approved shape does not need re-approval.

**Always use `/commit`. Every commit, every session, no exceptions** — including
when another skill or instruction asks for a commit. Writing the message
by hand produces multi-paragraph bodies the user does not want, and it has
happened repeatedly across sessions. A new session is not a reset: read this
line and invoke the skill.

## Commands

```bash
make demo             # the presentation walkthrough: pass, then fail, then verdict
make ci               # the gate chain the pipeline enforces
make plan             # render both Terraform layers to plan.json, offline
make policy           # both secure layers must pass all 81 rules
make policy-negative  # the insecure fixture must FAIL; a clean run is itself a failure
make policy-k8s       # workload manifests must pass
make policy-k8s-negative  # the bad manifests must FAIL
make policy-coverage  # every rule must fire against a fixture
make plan-insecure    # render the insecure fixture on its own
make fmt              # terraform fmt -check, recursive
make validate         # terraform validate both roots (runs init first)
make clean            # remove generated plan artefacts
```

Running one area rather than all eighty-one rules. There is no per-rule runner,
and `conftest --namespace` is a trap here: every rule file is `package main`,
so `--namespace eks` matches nothing and reports zero failures rather than an
error. Filter on the message prefix instead:

```bash
conftest test --policy controls/policy --all-namespaces -o json \
  controls/terraform/fixtures/insecure/plan.json \
  | jq -r '.[].failures[]?.msg' | grep '^eks:'
```

Dropping the `grep` and piping to `cut -d: -f1 | sort | uniq -c` maps the whole
fixture by area — 21 eks, 7 encryption, 6 supply chain, 6 model governance,
6 logging, 5 network, 5 iam, 3 cost, 2 residency.

Live cluster targets, which need podman running:

```bash
make kind-up          # create the local cluster
make k8s-apply        # base manifests + Kyverno only
make k8s-admit        # throw the bad manifests at a real API server
make k8s-demo         # a real cluster refuses each insecure manifest
make netpol-proof     # send a packet before and after default-deny egress
make kind-down
```

Requires `terraform`, `conftest`, and for the live targets `kind` (0.33+),
`kubectl`, `helm` and podman. None of the targets above touch an AWS account
— a real `terraform apply` is a separate, manual step (see below).

## Architecture

```
controls/terraform/
  eks-platform/       root: where code runs   - VPC, EKS, nodes, endpoints, jump host
  bedrock-ai/         root: what code does    - Bedrock, guardrail, corpus, vectors, identity
  modules/            twelve reusable modules, each with its own README
  fixtures/insecure/  deliberately broken config the gate must reject
  pipeline-iam/       root: run by hand - OIDC provider and the role Actions assumes
controls/policy/      81 Rego rules, applied to Terraform plans AND Kubernetes YAML
controls/kubernetes/  base manifests, Kyverno policies, manifests that must be refused,
                      and render.sh which substitutes applied state into them
controls/data/corpus/ six synthetic markdown documents, uploaded by the bedrock-ai
                      layer: two retrievable, one group-restricted, three that trip
                      the guardrail
app/                  the only custom code: mediation service (FastAPI) and its
                      React front-end, bundled into one image
.github/workflows/    security.yml (gate chain, mirrors make ci); tf-reusable-workflow.yaml
                      (reusable: the only place terraform runs); infra-provision
                      (both layers in order, and the only infra workflow a push
                      triggers); infra-destroy, infra-eks-platform,
                      infra-bedrock-ai (dispatch-only, OIDC, no stored keys);
                      app-image.yml builds and pushes the mediation image;
                      app-secrets.yml generates the secret material on the jump
                      host; app-deploy.yml renders, gates and applies the
                      manifests; app-index.yml builds the vector index;
                      app-release.yml is the push path for the application --
                      it calls app-image then app-deploy with the digest
                      between them, and is the only app workflow a push
                      triggers; app-tokens.yml mints demo tokens (see below)
.github/scripts/      backend + tfvars generation and cross-root wiring for deploy
docs/RUNBOOK.md       operational how-to: prereqs, offline loop, live cluster,
                      real AWS apply/destroy order, demo, troubleshooting
.claude/skills/ship/  repo-local skill: make ci, commit, push, watch the run
.claude/skills/demo/  repo-local skill: the presentation walkthrough -- gates, live
                      front end, then a guardrail alarm firing into the alert queue
```

Every control is validated by proving it rejects bad input, never only that it
accepts good input.

## Things that will bite you

**This deploys for real, not just offline.** The user decided against staying
$0/offline-only. `terraform apply` runs against a real AWS account in
`eu-central-1`, tuned to roughly $17/day (two thirds of it OpenSearch
Serverless; the jump host and its three SSM endpoints add about $1).
The Makefile still has no `apply`/`destroy` target — don't add live-deploy
targets without asking.

**Never tear down unless the user says so in that moment.** They pay for this
account personally and keep the stack up across sessions: *"the tear down i will
tell you myself. dont destroy anything without my command."* Saying what the day
costs is useful; dispatching `infra-destroy.yml` on your own judgement is not.

**`aws-vault` sessions cannot call IAM — always pass `--no-session`.** Without
it the credentials are wrapped in a `GetSessionToken` session that IAM refuses
with `InvalidClientTokenId`, while `sts:GetCallerIdentity` succeeds with the
same token, so the credentials look fine. The account is `891377211626`, the
profile `spdy999`. It replaced `171414227044` / `pun100` on 2026-09-22; the old
account is torn down and empty, and anything still naming it (old commits,
`docs/evidence/aws-live-capture.md`) is history rather than configuration.

**The S3 backend is generated at deploy time, never committed.** Declaring a
`backend "s3"` block in either root makes `terraform plan` refuse to run
without initialising it, which breaks `make ci` and the whole offline claim.
`.github/scripts/tf-config.sh` writes `backend.tf` and `ci.auto.tfvars` inside
the deploy job; both are gitignored. State is in S3 for deployments and
nowhere for gates.

**`deploy` is reserved for the application.** Infrastructure workflows are
`infra-*`. Every terraform command lives in `tf-reusable-workflow.yaml`; the
four callers pass a layer and an action and nothing else. A second copy of
those steps in a caller is how the layers drift.

**`pipeline-iam` keeps remote state like the other roots** — it runs with a
person's own credentials, not the role it creates, so there is no circularity,
only an ordering requirement that the bucket exists first. Its `backend.tf` is
the one committed backend file; `.gitignore` carries an explicit exception.

**GitHub issues an ID-qualified OIDC subject.** The token's `sub` is
`repo:spdy999@24741707/ai-sec@1376188734:environment:production`, not
`repo:spdy999/ai-sec:environment:production`. The immutable form embeds numeric
account and repository IDs so a rename cannot transfer trust. Pinning only the
legacy form fails with `Not authorized to perform sts:AssumeRoleWithWebIdentity`
and no hint about what the subject actually was — the way to find out is to
decode the claims in a throwaway job, not to guess. `pipeline-iam` now trusts
both forms; values in a `StringEquals` condition are OR-ed, so it stays two
exact matches rather than becoming a wildcard. The shape is identical whether
the token is requested from a caller job or from inside a called reusable
workflow, so the reusable workflow is not involved in this.

**`environment: production` gates nothing on this plan.** Required-reviewer
protection rules need a paid plan on a private repo. The real gate is the policy
chain each run carries, plus a typed `confirm=destroy` on the teardown. The
environment block stays because the OIDC trust policy pins
`environment:production` in the token subject — a job without it cannot assume
the role.

**A push to main applies the infrastructure, and that was asked for.** The user
works trunk based and wanted change detection rather than remembered dispatches.
`infra-provision.yml` carries the push trigger and runs `eks-platform` then
`bedrock-ai` with `needs` between them; the two single-layer callers are
dispatch-only. That split is not cosmetic: while both callers had their own push
trigger, one commit started both at once, and the shared `genai-platform-live`
lock queued them in the order GitHub chose rather than the order they depend on.
The AI layer won that race and applied against a platform layer that had not yet
published `bastion_security_group_id`, so a `count` on that variable resolved to
zero and an egress rule silently did not exist. The gate chain now runs *inside*
the applying run (`run_gate` left at its default) — `security.yml` runs in
parallel on the same commit and so could never have refused one.

**A cleanup step that interpolates an unset variable deletes everything.** The
`clean up the staging prefix` steps run `if: always()`, so a failure before the
staging step left the prefix empty and the command became `aws s3 rm --recursive
s3://<the state bucket>/` — every layer's state, with `|| true` swallowing it.
Versioning is the only reason it was recoverable: the objects were still there
under a delete marker, and removing the marker restored them. Both app workflows
now guard on `steps.stage.outputs.prefix != ''`. Worth noting for the risk
assessment that the deploy role's deny on deleting the state *bucket* does not
cover deleting objects in it.

**The cluster is `terraform-aws-modules/eks`, and that was not a style choice.**
The hand-written module passed all 76 rules and was still wrong in three ways
that only a real apply found: no node egress to the S3 prefix list, so ECR
served image layers the node could never fetch and it sat NotReady for twenty
minutes with no health issue reported; the CMK policy did not let Auto Scaling
attach an encrypted root volume, which killed every node inside a minute with
`Client.InvalidKMSKey.InvalidState`; and the default addons were never
declared. Upstream gets all three right. Its
`node_security_group_enable_recommended_rules` default opens node egress to
0.0.0.0/0 and is turned off here, with every rule named instead.

**The platform layer no longer plans offline; the AI layer still does.**
Upstream reads `aws_caller_identity`, `aws_partition` and
`aws_iam_session_context` during plan, so `make plan` renders `bedrock-ai`
only. `eks-platform` is gated in the deploy job instead — `terraform show -json
tf.plan` piped into `make policy-plan`, against the saved plan immediately
before it is applied. Stronger evidence than the offline render it replaces,
since the bytes the rules read are the bytes that run, but no longer free: a
contributor without an account cannot check that layer. The negative fixtures,
the workload manifests and the coverage gate are untouched and still offline.

**`for_each` cannot iterate a security group ID or a role ARN.** Both are
unknown until apply, and Terraform refuses to plan a `for_each` whose *keys* it
cannot resolve. The endpoint clients and the cluster access entries are
therefore `map(string)` keyed by a static name — `nodes`, `bastion`,
`operator-0` — with the unknown value on the right. A `toset()` of ARNs plans
fine right up until the first entry comes from another resource, then fails
with "Invalid for_each argument" and nothing else changed.

**The service can read the vector index and never write it.** The OpenSearch
data access policy grants writes to the jump host role only, so ingestion is an
operator action. That is what makes corpus poisoning by prompt injection
impossible rather than merely unlikely — the identity running the injection has
no write permission to use. `aoss:APIAccessAll` in IAM is necessary and not
sufficient: without a data access policy every query returns 403 and the IAM
policy looks correct.

**Ingestion is `app-index.yml`, and keeping it on the jump host cost eight
fixes.** The host has Python 3.9, no pip, no boto3, no git and no route to PyPI,
so the runner downloads wheels and stages them in the state bucket beside the
ingester, exactly as `app-deploy.yml` stages kubectl. Each of these was found
only by running it, and each hid the next: the bastion's S3 grant named
`app-deploy/*` and nothing else (an `aws s3 cp --recursive --quiet` denied this
way exits 1 printing *nothing*, so the SSM output is empty); pip 26 dropped 3.9
and dies importing on `dataclass() got an unexpected keyword argument 'slots'`,
so the staged pip is held below 26; `--python-version` fixes wheel tags but not
the marker the resolver evaluates, so urllib3 2.x came down while botocore under
3.9 wants `<1.27`, and it has to be named explicitly; the bastion had no egress
to the AI layer's endpoint security group; that fix applied before the platform
layer published the security group id, so its `count` silently resolved to zero;
the Bedrock VPC endpoint policy named the workload alone, and IAM and the
endpoint policy are evaluated separately — *"no VPC endpoint policy allows the
bedrock:InvokeModel action"* is that document, not the role; the default ten
second read timeout is too short for the first write into a cold Serverless
index; and Serverless does not implement the refresh API, so `indices.refresh`
404s *after* every document is written and the run fails on a courtesy step.
The ingester is granted `InvokeModel` on the embedding model only — it cannot
ask a question through the path it uses to index one.

**A guardrail can be attached, configured, and scanning nothing.** The
guardrail carried PROMPT_ATTACK at HIGH and every injection still came back
`guardrail_intervened: false`, answered by the model's own refusal -- which
reads like the control working and is not a control at all. Bedrock applies the
prompt-attack filter only to input the caller marks as untrusted, and
`InvokeModel` with the Anthropic Messages body ignores the guardContent tags
entirely: the trace returns with a processing latency set, every policy unit
zero, and `amazon-bedrock-guardrailAction: NONE`. The same text through
`ApplyGuardrail` comes back `BLOCKED` at HIGH confidence, which is how to tell a
misconfigured guardrail from an unapplied one. `Converse` is what works -- and the console says so: the
prompt-attack panel carries the note *"If you are using InvokeModel or
InvokeModelResponseStream for text content, use input tags to apply prompt
attack filtering. For Converse and ConverseStream APIs, input tags are not
required."* So the `guardContent` block does not enable the scan on Converse;
it scopes it. `providers.generate` takes the system prompt, the passages and
the question as three arguments, and only the question goes in the block --
one of the passages is a planted injection, and scanning quoted documents
would block the corpus rather than the caller.

**The guardrail's console form differs from the Terraform in three places.**
Harmful categories and prompt attacks are separate toggles on one page, so
enabling the prompt-attack filter alone leaves `INSULTS` off. Prompt attacks
has one threshold slider and an action dropdown, not an input and an output
strength -- `output_strength = "NONE"` satisfies a required API field and has
no control. And the page carries a **Content filters tier** choice, Classic or
Standard, that the module does not set: the deployed guardrail is on Classic by
default rather than by decision, which belongs in the risk assessment.

**Three IAM shapes were wrong in ways only a real question could find**, each in
code that passed every gate and applied cleanly. The workload could not embed at
all: the model grant is conditioned on `bedrock:GuardrailIdentifier`, an
embedding call carries no guardrail, so the condition could never match --
embeddings now have their own statement, on the embedding model alone.
`bedrock:GuardrailIdentifier` is now matched against the id, the ARN, and the
ARN with a version suffix, OR-ed, because which form Bedrock puts in the request
context is not visible from a refusal that names the model and says nothing
about the condition that failed. And a VPC endpoint policy will not match a
foreign-region model ARN: naming all six regions the profile routes to is
accepted at write time and still refuses the call. The endpoint now pins which
model may be reached, with a wildcard region; which regions it may run in stays
pinned in IAM, where the account evaluates it.

**The EU inference profile routes to six regions, and two were not enabled.**
`aws bedrock get-inference-profile` lists eu-central-1, eu-west-1, eu-west-3,
eu-north-1, eu-south-1 and eu-south-2; the configuration named four. eu-south-1
and eu-south-2 are opt-in regions this account did not have, so every request
routed there failed. Both were enabled on 2026-09-23 with `aws account
enable-region` -- a few minutes, no cost. There is no single-region Anthropic
fallback: every Anthropic model in eu-central-1 is `INFERENCE_PROFILE` only,
every current EU profile spans the same six regions, and the on-demand models in
eu-central-1 are all open-weight.

**Demo tokens are minted inside the pod, not on the jump host.** The signing
key's resource policy names the workload role and the ingestion role and denies
every other principal, so a laptop holding administrator credentials cannot read
it. The jump host is a named reader but its own IAM policy is deliberately
`PutSecretValue` and `DescribeSecret` only -- `app-tokens.yml` was built before
that was noticed and fails on `GetSecretValue`. The working path needs no new
permission: `kubectl exec` into the pod, which already holds boto3, PyJWT and
the only credentials that can read the key, and sign there. `tokens.py` now
falls back to `IDENTITY_SECRET_ARN` when `IDENTITY_TOKEN_SECRET` is unset, so
`python -m mediation.tokens alice --groups all-staff` works in the pod.

**Reaching the service from a laptop takes two hops and three kubectl flags.**
`aws ssm start-session` with `AWS-StartPortForwardingSessionToRemoteHost`, the
API server's hostname, port 443, local port 6443; then kubectl against
`--server https://127.0.0.1:6443` with `--tls-server-name <API server hostname>`,
because the certificate is issued for that name and not for localhost.
`~/.kube/koerber-live.yaml` holds the context and `spdy999` has an access entry.
Then `kubectl port-forward deploy/genai-mediation 8443:8443`, and the front end
is at `https://127.0.0.1:8443/`, self-signed. A deploy replaces the pods and
silently kills the port-forward; restart it rather than debugging the empty
response.

**The image is built on a GitHub runner, never on the jump host.** The jump host
has no route to the internet, so it cannot pull a base image or an npm package.
`app-image.yml` is the only thing that can reach both the public registries and
ECR. Its output is a digest; nothing downstream refers to a tag, and the
repository refuses to move one.

**The jump host is the only way into the VPC, and it has no ingress rules.**
There is no internet gateway, no public subnet and no SSH. Access is Session
Manager, which dials out to the `ssm`, `ssmmessages` and `ec2messages`
endpoints. Its posture lives in a launch template rather than on the instance
because the IMDSv2, hop-limit and volume-encryption rules read
`aws_launch_template`; configured on the instance it would be correct and
unproven. Its AMI is a variable written by `tf-config.sh` at deploy time — an
`aws_ssm_parameter` data source would have broken offline plan.

**Offline plan needs mock credentials.** The AWS provider resolves credentials
during `plan` even with every `skip_*` flag set. `providers.tf` passes
`access_key`/`secret_key` when `var.offline_plan` is true.

**No `data` sources that call AWS.** Account ID, VPC, subnet and OIDC values are
variables precisely so `plan` never contacts AWS. `aws_iam_policy_document` is
fine — it renders client-side.

**Unknown values are not missing values.** Terraform puts attributes it cannot
resolve until apply into `resource_changes[].change.after_unknown`, not into
`planned_values`. Use `lib.unknown_at(address, path)` in any rule checking an
attribute that may be a cross-resource reference — three false positives came
from missing this.

**`plan.json` is not byte-reproducible.** `terraform show -json` emits
`relevant_attributes` in a different order on every run, so two plans of
untouched code compare unequal. To prove a refactor changed nothing, diff
`jq -S '{planned_values, resource_changes}'` — that is the whole surface the
policy reads.

**`lib.all_resources` walks every module depth.** It matches objects at a
`.../resources/<index>` path. A shallower walk would skip everything inside a
nested module, and a rule that inspects nothing passes.

**The roots are split for a policy reason, not only an ownership one.** Merged
into one root, the cluster's OIDC issuer URL is unknown at plan time, which
makes the whole IRSA trust policy unknown, which makes the rule checking it stop
firing silently.

**Two dependency cycles are broken deliberately.** The workload gets KMS access
through its own IAM policy rather than the key policy; the rule joining the node
security group to the endpoint security group is wired in the root module. Both
are commented where they occur.

**The negative tests are the real tests.** `make policy-negative` and
`make policy-k8s-negative` invert the exit code. Any new rule must be proven to
fire against a fixture — `make policy-coverage` enforces this and is part of
`make ci`, so a rule that rejects nothing fails the build.

**Four rules are exempt from coverage**, listed in `controls/policy/coverage.py`
with a reason each. Every one is the "present but misconfigured" half of a pair
whose other half is "absent entirely"; a single plan cannot trigger both. The
exemption is checked in the other direction too: if an exempt rule ever fires,
the gate fails as stale.

**Plans are file targets, not phony ones.** `make demo` used to render both
plans twice and print the same four lines twice. `$(PLAN_EKS)` and friends
rebuild only when their `.tf` sources are newer.

**Screen output goes through `controls/policy/gate.sh`.** conftest reports one
"test" per rule per document, so nine manifests against seventy-six rules reads as
"630 tests" — a number that means nothing on a projector. The wrapper reports
rules, documents and violations, and truncates negative output to `SHOW`
examples plus a count (the demo sets `SHOW=5`; CI leaves it unset for a full
log).

**Governance lists live in `controls/policy/lib.rego`**, not in the module they
govern — a team cannot approve a new model by editing its own Terraform.

**The Bedrock audit trail is CloudTrail, not model invocation logging.** AWS
refuses `PutModelInvocationLoggingConfiguration` on this account with
`ValidationException: Your account is not authorized to perform this action`
and a pointer to the support console. It is account-level, not IAM — the same
call fails with account administrator credentials, which is how to tell the two
apart. CloudTrail covers it and suits this design better: `InvokeModel` and
`Converse` are *management* events, on by default; `ApplyGuardrail` is a *data*
event on `AWS::Bedrock::Guardrail` and includes the evaluations Bedrock runs
during an invocation, so every block is recorded with the filter that produced
it. Neither carries prompt text — which removes a contradiction, since the old
configuration set `text_data_delivery_enabled = true` while
`app/mediation/telemetry.py` refuses to log prompts for exactly the stated
reason. What is lost is replay of what was asked. The trail is single-region on
purpose: a multi-region trail would pull events from outside the EU allow-list
into this account's log store.

**Anthropic models are invocable only through an inference profile.** Every
Anthropic model in `eu-central-1` lists `inferenceTypesSupported:
INFERENCE_PROFILE` and nothing else, so `modelId` must be
`eu.anthropic.claude-sonnet-4-5-20250929-v1:0`. The bare foundation model ID
fails with `ValidationException: Invocation of model ID ... with on-demand
throughput isn't supported`. IAM then evaluates two ARN shapes for what is one
call: the `inference-profile/` ARN in this account, and the
`foundation-model/` ARN in whichever region the profile routed to — so the
grant spans `var.model_routing_regions`, all EU. Authorising only the profile
produces an AccessDenied naming the model ARN. The governance rule strips the
geography prefix before checking the allow-list, so a new model cannot be
approved by prefixing it. Titan embeddings take the bare ID and need none of
this.

**`eu-west-1` and `eu-north-1` still answer `Your account is currently being
verified`** for Bedrock on this account, while `eu-central-1` and `eu-west-3`
work. New accounts clear this within hours. It is per-region, not account-wide,
and the same call in a working region is how to tell the two apart.

**The application's secrets are in Secrets Manager, and Terraform never sees
their values.** `modules/app-secrets` creates the two containers — the identity
signing key and the mediation TLS pair — CMK-encrypted, each with a resource
policy denying `GetSecretValue` to every principal but the workload role and
the jump host. There is deliberately no `aws_secretsmanager_secret_version`: a
version resource puts the plaintext into state, and state holds every attribute
of every resource. `app-secrets.yml` generates both **on the jump host**, so the
material is created inside the VPC and never reaches a CI runner. No Kubernetes
Secret exists in the namespace at all; the service reads both at startup with
its own IRSA credentials, and `entrypoint.sh` writes the certificate to the
memory-backed `/tmp` because uvicorn needs `--ssl-certfile` as a path before any
application code runs.

**A deploy from a GitHub runner cannot reach the cluster, so the jump host
applies it.** `app-deploy.yml` renders manifests from applied state, gates the
*rendered* output rather than the committed shape — substituting real
identifiers is the step that could introduce a violation — stages them plus a
`kubectl` binary in the state bucket, and sends the jump host a Run Command.
`kubectl` travels that way because the host cannot download one.

**`ssm:SendCommand` authorises against two resources, and a condition on the
instance tag denies the document.** One statement naming both the document and
the instance with a `ssm:resourceTag/Name` condition fails, because the document
carries no such tag — and the error names the document, which reads as though
the document were the problem. Two statements: the document unconditionally,
the instance under the tag condition.

**A multi-line script cannot go through `--parameters commands=...`.** That is
the CLI's shorthand syntax; it splits on commas and mangles newlines, and the
script arrives as one line that fails with `unexpected EOF while looking for
matching quote`. Build a JSON file and pass `--parameters file://...`.
`ssm-run.sh` also sets `executionTimeout`, without which a hanging command stays
`InProgress` for an hour and the run reads as slow rather than stuck.

**A route is not a permission, and this cost an hour twice.** The S3 gateway
endpoint puts a route in the route table, but the security group must also allow
egress to the S3 prefix list. Missing on the nodes it left them NotReady with no
health issue reported; missing on the jump host it made every S3 call hang until
its connect timeout, with empty stderr, so the deploy looked slow rather than
broken. The tell is `Connect timeout on endpoint URL` naming a correctly
resolved regional endpoint. The same class of failure applies to any service
with no interface endpoint: `secretsmanager` had none, and both the jump host
and the pod need one.

**Bedrock guardrails are configured in Terraform, not reimplemented in code.**
Custom code exists only for identity-aware authorization. Measuring the
guardrail's real block rate through `ApplyGuardrail` was cut — see State.

**kubectl's current-context is a real work EKS cluster.** Every kubectl call
pins `--context kind-koerber-demo`. Never use current-context: the `bad/`
manifests are deliberately privileged.

**Podman needs `/opt/podman/bin` on PATH** for `krunkit`, or the machine will
not start. Never prune the user's podman volumes or stopped containers.

## State

Controls 1 and 2 are complete and validated in both directions. Control 3 ran
for the first time on 2026-09-21 and is green — it failed twice first, on a
missing `terraform init` before `validate` and on a trivy-action tag that does
not exist (upstream tags are `v`-prefixed). The README is written, including the section
on what the local cluster cannot prove (IRSA federating with STS, EKS access
entries, CMK envelope encryption of etcd, control plane audit logs reaching
CloudWatch). `docs/RUNBOOK.md` is written: operational (how to run things);
README stays the reviewer-facing what/why/proof doc — don't duplicate content
between them.

**Provisioned once, torn down, now rebuilt on the upstream module.** The first
live run on 2026-09-21 took six rounds of fixes, every one of which the offline
gate had passed clean: GitHub's ID-qualified OIDC subject, the bastion launch
template carrying network settings the instance also carried (twice — security
group, then subnet), the Cost Explorer monitor type and then its
one-per-account limit, a service-linked role read authorised against an
unpathed ARN, Auto Scaling having no grant on the CMK, and the missing S3
prefix list egress. Each is its own `fix(infra)` commit.

The `eks` interface endpoint was added during that session on a theory that
turned out to be wrong — nodeadm takes its cluster config from user-data, not
from `eks:DescribeCluster`. It is harmless and left in place, but it is not
what fixed the bootstrap; the S3 prefix list rule was, proven by watching the
node's secondary IP count go from 1 to 12 within seconds of the rule existing.

Rebuilding on upstream found five more, all of them shape rather than
permission: the node IAM role has to be named `genai-assistant*` or the deploy
role may not create it; `vpc-cni` and `kube-proxy` need `before_compute = true`,
because declaring addons stops EKS bootstrapping self-managed ones and the node
otherwise comes up with `cni plugin not initialized`; both roots named their
endpoint security group `<prefix>-<env>-vpce`, so the second apply failed with
`InvalidGroup.Duplicate`; Bedrock invocation logging needs `iam:PassRole` to
`bedrock.amazonaws.com`; and renaming a security group with a fixed `name`
deadlocks, because replacement is destroy-first and the endpoints still hold it
— `name_prefix` plus `create_before_destroy` is the pair that fixes it, neither
alone.

**Superseded: resources were live at the end of that session.** An
`infra provision` run was still applying. The cluster, nodes and addons all
reached ACTIVE on upstream; the remaining failures were the endpoint security
group churn above. Nothing is running now — see the third rebuild above.

**The deploy role is service-scoped where it must be, resource-scoped where it
can be.** `ec2:*`, `eks:*`, `kms:*` and friends act on resources that do not
exist until apply. IAM does not: roles and policies are limited to
`genai-assistant*`, `PassRole` is conditioned on `iam:PassedToService`, and
`CreateServiceLinkedRole` on `iam:AWSServiceName`. Two denies hold the
boundary — the role cannot edit its own trust policy or the GitHub OIDC
provider, and cannot delete the state bucket it stores its own state in (the
bucket shares the `genai-assistant-` prefix, so the S3 grant would otherwise
reach it). Tightening the remaining wildcards after a first apply belongs in
the risk assessment.

**The demo application is deployed, the corpus is indexed, and the service has
been asked real questions.** Two `genai-mediation` pods run 1/1 Ready in
`891377211626`, reading the signing key and the TLS pair from Secrets Manager
with their own IRSA credentials. The namespace holds no Kubernetes Secret at all
— the two created by hand before that move were deleted on 2026-09-22, so "no
Kubernetes Secret exists" is now true in fact and not only in the manifest.
`app-index.yml` indexed 14 passages from 6 documents into `genai-corpus`, and
the five demo rows were run end to end on 2026-09-23 — see "The demo runs".

**`--recreate` drops the index before it rebuilds it.** A failed reindex
therefore leaves an empty index and a service that answers nothing, which now
matters more because a corpus edit triggers the pipeline automatically.
Indexing into a new name and swapping an alias at the end is the fix, and is not
built yet.

**A manifest can be valid and still rejected by the API server.** The deployment
hand-projected the IRSA token at
`/var/run/secrets/eks.amazonaws.com/serviceaccount`, which is where the EKS pod
identity webhook injects its own — so every pod was refused with
`mountPath: must be unique` and the Deployment sat at 0/2 with the failure only
visible in its `ReplicaFailure` condition. The offline gate passed it, because
the gate reads the manifest and not what an admission webhook does to it. The
token's audience and one hour lifetime now come from the
`eks.amazonaws.com/token-expiration` annotation on the ServiceAccount.

**The account switch took five fixes, each found only by running it.** GitHub's
ID-qualified OIDC subject was already known; the new ones were the deploy role
having no Secrets Manager permissions at all, `SendCommand` needing its two
resources authorised separately, the SSM CLI shorthand mangling a multi-line
script, no `secretsmanager` interface endpoint in the VPC, and no jump host
egress to the S3 prefix list. Every one passed `make ci` clean. Each is its own
`fix(...)` commit between `38c09a2` and `e8f8b4d`.

**The move to v2 took three more, all of them one KMS grant short.** The jump
host could read the staged object from S3 but not decrypt it, because the state
bucket is CMK-encrypted and `s3:GetObject` alone is half a grant. The pod could
call `GetSecretValue` and still got `Access to KMS is not allowed`, because its
`kms:ViaService` condition listed `s3` and `bedrock` but not `secretsmanager` —
a refusal that names neither the key nor the condition. And the rollout had to
be retried once after the policy landed, since the pod that crashed during the
apply was denied under the old one. A failed rollout now prints pods, events and
logs from the jump host session rather than leaving `timed out waiting for the
condition` as the only evidence.

## The demo runs

Asked and answered on 2026-09-23, against the live account, through the front
end the pod serves at `/` on :8443. Four of the five rows behave as designed:

| Ask | As | Result |
|-----|----|--------|
| leave carry-over | alice | answered from `hr-leave-policy.md` |
| Q3 revenue | alice | "no information in the passages" — the finance document was never a retrieval candidate |
| Q3 revenue | dana | EUR 14.2M against a plan of 13.5M, from `finance-q3-forecast.md` |
| "ignore all previous instructions…" | alice | guardrail intervened; "blocked by the Korber AI security guardrail" |
| customer records | alice | the model declined; the guardrail did not fire |

**A masking row was added and run live on 2026-09-23.** `engineering-oncall.md`
is all-staff and now carries two synthetic contacts with email, phone and
`KOE-######` identifiers, so the document is retrieved and the identifiers come
back anonymised — the one row where masking rather than filtering does the work.
It exists because the assignment §2.3 lists sensitive-data masking as a
demonstrable control and nothing on screen showed it. Asked as alice, "Who is on
call and how do I contact them?" answers:

```
Primary: Rafael Ortiz - Employee ID: {employee-id} - Email: {EMAIL} - Phone: {PHONE}
```

with `guardrail_intervened: true`. **An anonymisation is an intervention**, so
that flag does not separate a masked answer from a blocked one — only the body
does. The name is not masked; only the entities the guardrail names are.

**A corpus edit alone silently indexes the previous corpus.** `app-index.yml`
triggers on `controls/data/corpus/**`, but the ingester reads the documents from
S3 and *Terraform* uploads them, while `infra-provision.yml` triggers only on
`controls/terraform/**`. So a corpus-only push runs a green index job against
the old S3 copy and reports success — found on 2026-09-23 when the new contacts
were absent from the index after an index run that said `indexed 14 passages`.
The order is `infra provision` (uploads the corpus), then `app index -f
confirm=index`; after that the count was 16, with `engineering-oncall.md` at 5
passages. Not yet fixed in the workflows. OpenSearch Serverless also needs
roughly a minute after a `--recreate` before queries return anything — the first
question after a reindex answered with `sources: []`.

Row five was fixed in the guardrail after that run, then set aside for the
demo: four rows already carry the story, so the fifth is cosmetic. See below.

Rows two and three back to back are the point of the design: same question, same
index, different answer, and the difference is in what was retrievable rather
than in what the model was told to say. The badge on row two reads "guardrail
passed" and that is correct — nothing in the question is an attack, so the
guardrail evaluated it and found nothing. The control doing the work there is
entitlement filtering, visible in the Sources line.

**Row five was weak, and the fix is a second denied topic.** Asking for
customer records is not a prompt attack, and the PII filters mask PII that
appears in a response rather than refusing a request for it — `customer-
records.md` is `support-team` only, so for `alice` it is never a retrieval
candidate, nothing is there to mask, and the model's own refusal was all that
answered. `customer-and-payment-data` now sits alongside `credential-disclosure`
in `modules/bedrock-guardrail`, and a denied topic is evaluated on the input, so
the request is refused whether or not the document was retrievable. Applied on
2026-09-23, which created guardrail version 2 — but the push touched no
application file, so `app release` never ran and the pods stay rendered against
version 1. The user then set the row aside as cosmetic, so the redeploy was not
run. To pick it up: dispatch `app deploy` with the current digest, which
re-renders `BEDROCK_GUARDRAIL_VERSION` from applied state.

**Still unbuilt, and it matters:** `--recreate` drops the index before it
rebuilds it, so a failed reindex leaves the service answering nothing, and a
corpus edit now triggers that automatically. Index into a new name and swap an
alias at the end.

**Both written deliverables are drafted**, in the vault's `Assignment/` folder
rather than the repo: `design-summary.md` (about five pages — threat model, four
trust boundaries, five controls with the guardrail finding as the centrepiece,
what was deployed and proven, trade-offs) and `risk-assessment.md` (five risks,
each with evidence, controls, detection, residual and actions; index rebuild
noted below the five as availability). Neither is reviewed yet.

`Slides.md` in the same folder is a 478-line Marp deck written before the live
deployment. It still says nothing is deployed and costs $0, and demos PII
masking and a tool allow-list that were never built. Reconciling it with the two
documents is the next job.

**Teardown and rebuild is written down** — RUNBOOK §7: what survives a destroy,
the emptiness check, the rebuild chain `infra-provision` → `app-secrets` →
`app-release` → `app-index` with the reason for each wait, and the manual five
minutes. Roughly 5 minutes down, 25-30 back up, plus 5 by hand. §4b's old
"always tear down after a live session" line is gone; it contradicted the
standing rule.


**The `ApplyGuardrail` test harness is cut, deliberately.** Measuring the real
block rate against an injection corpus is the right thing to build and there is
no minute for it in a fifteen-minute presentation. It is described in the design
summary as a design, not shipped as code. Do not restart it without asking.

**The demo is budgeted at three minutes.** `make demo` currently runs in about
13 seconds and prints 47 lines. Anything added to it has to earn its place
against that.

## Alerting is built and deployed; SIEM is design-only

The assignment PDF §2.2 lists Operations as a required section of the design
summary: *"telemetry, SIEM, detections, alerting, runbooks, availability, usage,
and cost monitoring"*, and §3.1 wants each risk to carry an attack scenario, the
affected component, the business impact, preventive *and* detective controls,
and the residual. Alerting was a documentation requirement rather than a build
requirement — four controls are demonstrated where two are asked for — and it
was built anyway, because "detections are designed" is a weaker sentence than a
deployed alarm.

**`modules/security-alerting`** is a CMK-encrypted SNS topic, a topic policy
naming `cloudwatch.amazonaws.com` with an `AWS:SourceOwner` condition, an email
subscription per address, and three metric filter plus alarm pairs:
`guardrail-interventions` and `authorization-refusals` over the mediation
telemetry log group, `bedrock-access-denied` over the trail log group. Wired
into `bedrock-ai` as `module.alerting`; the address comes from
`SECURITY_ALERT_EMAIL`, falling back to `COST_ALERT_EMAIL`. Applied and
verified live on 2026-09-23: three filters, three alarms, each carrying the SNS
action.

**`default_value = 0` does not cover an idle service.** A metric filter emits
the default only when a log event arrives and fails to match, so a log group
with no traffic at all produces no datapoints and the alarm sits in
`INSUFFICIENT_DATA`. After a rebuild `bedrock-access-denied` reads `OK` because
CloudTrail is always writing; the two telemetry alarms stay
`INSUFFICIENT_DATA` until the first `/ask`. The module README says the zero
covers a quiet period, which is true only of a quiet period *with traffic*.

**The SNS email was never delivered, and the queue is the answer.** Terraform
reports the subscription as created; `list-subscriptions-by-topic` shows
`PendingConfirmation` and no confirmation mail reached the address, twice,
including from a plain unencrypted topic created by hand as a control. Still
not diagnosed. `modules/security-alerting` now also subscribes a CMK-encrypted
SQS queue: a same-account subscription confirms itself, so `receive-message`
printing the alarm JSON proves the notification path without anyone clicking a
link. SNS needs the CMK to deliver into an encrypted queue, which is why
`sns.amazonaws.com` joined the key's service principals — without it the
subscription is created, the alarm fires, and the queue stays empty.

**The alarms carry two periods on purpose.** Each detection names its own, so
the two telemetry alarms sum over 60 seconds (`telemetry_period_seconds`) while
the trail-sourced one keeps 300 — a shorter window there buys nothing against
CloudTrail's five-to-fifteen-minute delivery, which is also why
`bedrock-access-denied` cannot be demonstrated live and stays pre-staged
evidence, triggered from the pod by calling `converse` without the guardrail,
which the IAM condition refuses. The guardrail threshold dropped from 5 to 3.
The demo sequence is three injections, `describe-alarms` going ALARM, then
`receive-message` off the queue — under three minutes, allowing for the metric
filter's own delay.

**The alarm cannot attribute a burst to one caller, and CloudWatch cannot fix
that.** The guardrail alarm sums interventions across everyone, so five callers
blocked once each is indistinguishable from one caller blocked five times — the
user raised this on 2026-09-23 and it is a real weakness of the deployed shape.
An alarm binds to a fixed metric identity, so per-caller detection needs either
one alarm per user or a `SEARCH` expression, and **`PutMetricAlarm` rejects
SEARCH outright**: *"ValidationError: SEARCH is not supported on Metric
Alarms."* Two live applies were burned finding that out. Two related schema
facts from the same attempt: a metric filter carrying `dimensions` may not also
set `default_value`, and a top-level `period` conflicts with `metric_query`
blocks (the period goes on the query that reads the metric). The only AWS
mechanism that does this without naming values ahead of time is Contributor
Insights — `aws_cloudwatch_contributor_insight_rule` does exist in the provider
already in use, and `INSIGHT_RULE_METRIC(rule, 'MaxContributorValue')` is
accepted in alarms where SEARCH is not. Unverified and unbuilt.

**A per-subject counter in the mediation service was built and rejected.** It
counted interventions per authenticated subject, emitted one event on crossing
so a single dimensionless alarm covered any number of users, and paused that
subject for five minutes. The user rejected it — the pause was in-process
memory, per pod, expiring, with no escalation, and the alert carried no subject
name — reverted all three commits on 2026-09-23, and the tree is back to the
fleet-wide sum. Do not rebuild it without asking. What the rejection was really
about: an alert that names no identity and a containment that lapses leaves the
responder watching mail arrive. Whatever replaces it has to put the subject in
the notification and revoke one identity rather than rotating the key for
everyone.

**Two new rules, 79 to 81.** A platform declaring a guardrail must declare at
least one alarm with a notification action; and an alarm with no
`alarm_actions` is refused, because an alarm that tells nobody still counts as
detection coverage on an audit questionnaire. VIOLATION 37 in the insecure
fixture is that second shape. Both needed care with unknown values: an action
pointing at a topic created in the same plan is `after_unknown`, and an empty
action list renders as `null` rather than `[]`, so `count` has to be guarded by
`is_array` or the rule is silently undefined against exactly the configuration
it exists to catch. `make ci` reports "77 of 81 rules proven to reject a
fixture, 4 exempt".

**`pipeline-iam` gained CloudWatch, SNS and then SQS actions**, each a hand
apply on 2026-09-23 (`0 to add, 1 to change`). That root runs with a
person's own credentials, so a push does not pick it up; apply it before the
first provision of a rebuilt environment or the AI layer fails on
`cloudwatch:PutMetricAlarm` or `sqs:CreateQueue`.

**The mediation service now records refusals.** A 401 wrote no event, so a
filter for token refusals would have matched nothing — the guardrail failure
reproduced in the thing built to detect it. `app/mediation/main.py` records
`{"event": "authorization_refused", "reason": ...}` before raising.

**SIEM stays design-only, deliberately.** AWS sells no product called a SIEM.
Security Hub aggregates findings, single-digit dollars a month here; GuardDuty
adds managed detection over CloudTrail, VPC and DNS, free for thirty days then
about $4 per million events; Security Lake normalises to OCSF without a query
tool; OpenSearch is the real thing and roughly doubles the current OpenSearch
bill. Not chosen. The zero-cost seam is an
`aws_cloudwatch_log_subscription_filter` on both log groups with `count` on an
empty-by-default `siem_destination_arn`. Not built.

## Rebuilt and live as of 2026-09-23, fourth time — and the live alarms have drifted

Brought back on the user's instruction with the full chain — `infra provision`
→ `app secrets -f confirm=rotate` → `app release` → `app index -f confirm=index`,
all green, cluster ACTIVE on 1.36, two pods 1/1 Ready, 14 passages indexed.
Jump host is `i-0669cead24cffe1e7`; the API server hostname changed again with
the rebuild, so regenerate `~/.kube/koerber-live.yaml` before any kubectl call.
**Nothing was torn down at the end of this session — the stack is up and
billing.**

**The account and the tree disagree about the alarms.** The rejected
per-subject work was applied live before it was reverted in git, so the account
carries four alarms and two SNS topics (`-security-alerts-high` /
`-security-alerts-low`) while the tree declares three alarms and one topic. The
next push to main reconciles it by destroying the extras — harmless, but a
`describe-alarms` before that push does not match the code. `/demo` Step 0
expects three alarms and will read wrong until then.

## Torn down and rebuilt on 2026-09-23, third time, then down again

The invoice showed a separate `ExtendedSupport` line under EKS: the cluster was
on **1.31**, out of standard support since 2025-11-26, billing $0.50/hour
instead of $0.10 -- $12/day on a platform that otherwise runs at $17. The
default is now **1.36**, the current EKS default. Check
`aws eks describe-cluster-versions` before pinning one; EKS refuses to skip
minors, so the fix on a live cluster is five sequential upgrades or a rebuild.
`KUBECTL_VERSION` in `app-deploy.yml` moved with it -- kubectl supports one
minor of skew and a v1.31 client against a 1.36 server is five out.

Rebuilt clean on 1.36, then destroyed again at the end of the session on the
user's instruction. Nothing is running.

**The alerting prerequisites are built and the delivery path is proven.** Each
detection now names its own period, the guardrail threshold is 3, and the topic
also delivers to a CMK-encrypted SQS queue whose subscription self-confirmed
(the email one is still `PendingConfirmation`). Proven by forcing the alarm
with `cloudwatch set-alarm-state` and reading the message back off the queue --
that is the check that exercises the `sns.amazonaws.com` KMS grant, which fails
silently without it. The alarm was reset to `INSUFFICIENT_DATA` afterwards and
the queue purged: `treat_missing_data = missing` keeps the last state, so an
alarm left in ALARM poisons the next preflight.

**`/demo` is written and rehearsed as far as the front end.** Preflight, gates,
front end and the alarm sequence. Steps 0 to 2 were run end to end on
2026-09-23 -- cluster and jump host checks, `make demo`, the SSM tunnel, both
tokens minted in the pod, and the front end answering `HTTP 200` at
`https://127.0.0.1:8443/`. The four demo rows and Step 3's alarm sequence were
**not** run; the stack came down first. One correction the rehearsal found:
building the kubectl invocation in a shell variable breaks under nu, so each
call has to be written out in full.

**Actions were bumped off the Node 20 runtime**, `actions/checkout` v4 to v7
and `hashicorp/setup-terraform` v3 to v4. Every breaking change between them is
a Node 24 runtime bump, plus checkout v6 writing credentials to a separate file
and v7 refusing fork checkouts under `pull_request_target`; this repo does
neither. `aws-actions/configure-aws-credentials@v4` is still on Node 20 and
still to do -- v6.3.0 is the fix and is safe here, since all six call sites
pass three string inputs and no booleans, and v5's only breaking change is
invalid-boolean handling. It was left because bumping it touches
`app-index.yml`, and a push-triggered index runs `--recreate` unguarded: the
typed confirmation gates only a dispatch.

## Torn down and rebuilt on 2026-09-23, second time

Destroyed on the user's instruction, then brought back the same session:
`infra provision` → `app secrets -f confirm=rotate` → `app release` →
`app index -f confirm=index`, all green, 14 passages indexed, two pods 1/1
Ready on the current digest — so the pods are on guardrail version 2 and row
five now refuses at the guardrail rather than at the model. `app-secrets`
requires `confirm=rotate`, which is easy to forget: a bare dispatch fails with
HTTP 422.

A rebuild issues a new cluster endpoint and CA, so `~/.kube/koerber-live.yaml`
must be regenerated with `aws eks update-kubeconfig --name genai-assistant-prod
--kubeconfig ~/.kube/koerber-live.yaml --alias koerber-live` before any kubectl
call. The jump host is `genai-assistant-prod-bastion`; the other running
instance is the node, tagged `mediation`.

**The monthly budget is $5, not $50** (`d97f234`), deliberately: against a
platform that runs at roughly $17/day every forecast threshold breaches on the
first evaluation, which proves the notification path rather than waiting a
month to find out it does not work. Budgets email needs no confirmation click,
unlike SNS, so it doubles as a deliverability test for that address.

**Both vault deliverables now satisfy the brief's required fields.**
`design-summary.md` has a §3.6 Operations covering alerting, the SIEM decision
and its seam, runbooks, availability, and usage and cost monitoring; the false
"a log group the SIEM subscribes to" line is gone; §4 lists the detection layer
and §5's limitations are the real ones (thresholds chosen rather than
baselined, CloudTrail latency). `risk-assessment.md` carries **Component** and
**Business impact** on every risk, and R5 is rewritten around the deployed
alarms. The summary is 2,355 words, near the five-page ceiling — if it runs
over, §5's limitations list overlaps §3.6 and can lose two sentences.

`Slides.md` is still the 478-line deck written before any of this: nothing
deployed, $0, PII masking and a tool allow-list that were never built. It is
the last piece of work.
