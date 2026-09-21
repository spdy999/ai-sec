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
make policy           # both secure layers must pass all 70 rules
make policy-negative  # the insecure fixture must FAIL; a clean run is itself a failure
make policy-k8s       # workload manifests must pass
make policy-k8s-negative  # the bad manifests must FAIL
make policy-coverage  # every rule must fire against a fixture
make plan-insecure    # render the insecure fixture on its own
make fmt              # terraform fmt -check, recursive
make validate         # terraform validate both roots (runs init first)
make clean            # remove generated plan artefacts
```

Running one area rather than all seventy rules. There is no per-rule runner,
and `conftest --namespace` is a trap here: every rule file is `package main`,
so `--namespace eks` matches nothing and reports zero failures rather than an
error. Filter on the message prefix instead:

```bash
conftest test --policy controls/policy --all-namespaces -o json \
  controls/terraform/fixtures/insecure/plan.json \
  | jq -r '.[].failures[]?.msg' | grep '^eks:'
```

Dropping the `grep` and piping to `cut -d: -f1 | sort | uniq -c` maps the whole
fixture by area — 20 eks, 7 encryption, 6 model governance, 5 network, 5
logging, 5 iam, 3 cost, 2 residency.

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
  eks-platform/       root: where code runs   - VPC, EKS, nodes, endpoints
  bedrock-ai/         root: what code does    - Bedrock, guardrail, corpus, vectors, identity
  modules/            eleven reusable modules, each with its own README
  fixtures/insecure/  deliberately broken config the gate must reject
  pipeline-iam/       root: run by hand - OIDC provider and the role Actions assumes
controls/policy/      70 Rego rules, applied to Terraform plans AND Kubernetes YAML
controls/kubernetes/  base manifests, Kyverno policies, and manifests that must be refused
.github/workflows/    security.yml (gate chain, mirrors make ci), infra-provision.yml,
                      infra-destroy.yml (both dispatch-only, OIDC, no stored keys)
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
`eu-central-1`, tuned to roughly $16/day (71% of it OpenSearch Serverless).
The Makefile still has no `apply`/`destroy` target — don't add live-deploy
targets without asking. Deployment is `infra-provision.yml` / `infra-destroy.yml`, both
dispatch-only. Always tear down after a live session.

**The S3 backend is generated at deploy time, never committed.** Declaring a
`backend "s3"` block in either root makes `terraform plan` refuse to run
without initialising it, which breaks `make ci` and the whole offline claim.
`.github/scripts/tf-config.sh` writes `backend.tf` and `ci.auto.tfvars` inside
the deploy job; both are gitignored. State is in S3 for deployments and
nowhere for gates.

**`environment: production` gates nothing on this plan.** Required-reviewer
protection rules need a paid plan on a private repo. The real gate is that
deploy and destroy are dispatch-only, plus a typed `confirm=destroy` on the
teardown. The environment block stays because the OIDC trust policy pins
`environment:production` in the token subject — a job without it cannot assume
the role.

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
"test" per rule per document, so nine manifests against seventy rules reads as
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

**The deployment pipeline exists but has never run.** `infra-provision.yml` and
`infra-destroy.yml` are written, dispatch-only and gate-chained; nothing has been
applied from them. Before a first deploy: apply `controls/terraform/pipeline-iam`
by hand, set the `TF_STATE_BUCKET` and `AWS_DEPLOY_ROLE_ARN` Actions variables
from its outputs, and create an Actions environment named `production` — the
OIDC trust policy pins it. None of that is done yet.

**The deploy role's infrastructure policy is service-scoped, not
resource-scoped** (`ec2:*`, `eks:*`, ...), because the ARNs it would name do
not exist until the first apply. It is already denied from editing its own
trust policy or the OIDC provider. Tightening it after a first apply belongs in
the risk assessment.

Outstanding: the five-page design summary and the top-5 risk assessment.

**The `ApplyGuardrail` test harness is cut, deliberately.** Measuring the real
block rate against an injection corpus is the right thing to build and there is
no minute for it in a fifteen-minute presentation. It is described in the design
summary as a design, not shipped as code. Do not restart it without asking.

**The demo is budgeted at three minutes.** `make demo` currently runs in about
13 seconds and prints 47 lines. Anything added to it has to earn its place
against that.
