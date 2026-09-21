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

## Commands

```bash
make demo             # the presentation walkthrough: pass, then fail, then verdict
make ci               # the gate chain the pipeline enforces
make plan             # render both Terraform layers to plan.json, offline
make policy           # both secure layers must pass all 76 rules
make policy-negative  # the insecure fixture must FAIL; a clean run is itself a failure
make policy-k8s       # workload manifests must pass
make policy-k8s-negative  # the bad manifests must FAIL
make policy-coverage  # every rule must fire against a fixture
make plan-insecure    # render the insecure fixture on its own
make fmt              # terraform fmt -check, recursive
make validate         # terraform validate both roots (runs init first)
make clean            # remove generated plan artefacts
```

Running one area rather than all seventy-six rules. There is no per-rule runner,
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
5 network, 5 logging, 5 iam, 3 cost, 2 residency.

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
controls/policy/      76 Rego rules, applied to Terraform plans AND Kubernetes YAML
controls/kubernetes/  base manifests, Kyverno policies, manifests that must be refused,
                      and render.sh which substitutes applied state into them
controls/data/corpus/ six synthetic markdown documents, uploaded by the bedrock-ai
                      layer: two retrievable, one group-restricted, three that trip
                      the guardrail
app/                  the only custom code: mediation service (FastAPI) and its
                      React front-end, bundled into one image
.github/workflows/    security.yml (gate chain, mirrors make ci); tf-reusable-workflow.yaml
                      (reusable: the only place terraform runs); infra-provision,
                      infra-destroy, infra-eks-platform, infra-bedrock-ai
                      (dispatch-only callers, OIDC, no stored keys); app-image.yml
                      builds and pushes the mediation image
.github/scripts/      backend + tfvars generation and cross-root wiring for deploy
docs/RUNBOOK.md       operational how-to: prereqs, offline loop, live cluster,
                      real AWS apply/destroy order, demo, troubleshooting
.claude/skills/ship/  repo-local skill: make ci, commit, push, watch the run
```

Every control is validated by proving it rejects bad input, never only that it
accepts good input.

## Things that will bite you

**This deploys for real, not just offline.** The user decided against staying
$0/offline-only. `terraform apply` runs against a real AWS account in
`eu-central-1`, tuned to roughly $17/day (two thirds of it OpenSearch
Serverless; the jump host and its three SSM endpoints add about $1).
The Makefile still has no `apply`/`destroy` target — don't add live-deploy
targets without asking. Deployment is `infra-provision.yml` / `infra-destroy.yml`, both
dispatch-only. Always tear down after a live session.

**`aws-vault` sessions cannot call IAM — always pass `--no-session`.** Without
it the credentials are wrapped in a `GetSessionToken` session that IAM refuses
with `InvalidClientTokenId`, while `sts:GetCallerIdentity` succeeds with the
same token, so the credentials look fine. The account is `171414227044`, the
profile `pun100`.

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
protection rules need a paid plan on a private repo. The real gate is that
deploy and destroy are dispatch-only, plus a typed `confirm=destroy` on the
teardown. The environment block stays because the OIDC trust policy pins
`environment:production` in the token subject — a job without it cannot assume
the role.

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

**Resources are live and billing as of the end of this session.** An
`infra provision` run was still applying. The cluster, nodes and addons all
reached ACTIVE on upstream; the remaining failures were the endpoint security
group churn above. Check the run and dispatch `infra-destroy.yml` before leaving
it — roughly $17/day.

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

**The demo application is written and has never run.** `app/` holds the
mediation service and its React front-end; `controls/kubernetes/base/` holds the
manifests, now with a ConfigMap, a Service and an operator port-forward network
policy. None of it has been built, pushed or applied, because nothing is
provisioned. The sequence is `docs/RUNBOOK.md` section 4c.

Outstanding: the five-page design summary and the top-5 risk assessment.

**The `ApplyGuardrail` test harness is cut, deliberately.** Measuring the real
block rate against an injection corpus is the right thing to build and there is
no minute for it in a fifteen-minute presentation. It is described in the design
summary as a design, not shipped as code. Do not restart it without asking.

**The demo is budgeted at three minutes.** `make demo` currently runs in about
13 seconds and prints 47 lines. Anything added to it has to earn its place
against that.
