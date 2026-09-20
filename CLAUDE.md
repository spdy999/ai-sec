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
make policy           # both secure layers must pass all 51 rules
make policy-negative  # the insecure fixture must FAIL; a clean run is itself a failure
make policy-k8s       # workload manifests must pass
make clean            # remove generated plan artefacts
```

Live cluster targets, which need podman running:

```bash
make kind-up          # create the local cluster
make k8s-demo         # a real cluster refuses each insecure manifest
make netpol-proof     # send a packet before and after default-deny egress
make kind-down
```

Requires `terraform`, `conftest`, and for the live targets `kind` (0.33+),
`kubectl`, `helm` and podman. Nothing needs an AWS account.

## Architecture

```
controls/terraform/
  eks-platform/       root: where code runs   - VPC, EKS, nodes, endpoints
  bedrock-ai/         root: what code does    - Bedrock, guardrail, corpus, vectors, identity
  modules/            ten reusable modules, each with its own README
  fixtures/insecure/  deliberately broken config the gate must reject
controls/policy/      51 Rego rules, applied to Terraform plans AND Kubernetes YAML
controls/kubernetes/  base manifests, Kyverno policies, and manifests that must be refused
.github/workflows/    the CI gate chain, mirroring make ci
```

Every control is validated by proving it rejects bad input, never only that it
accepts good input.

## Things that will bite you

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
`make policy-k8s-negative` invert the exit code. Any new rule should be proven
to fire against a fixture.

**Governance lists live in `controls/policy/lib.rego`**, not in the module they
govern — a team cannot approve a new model by editing its own Terraform.

**Bedrock guardrails are configured in Terraform, not reimplemented in code.**
Custom code exists only for identity-aware authorization and for measuring the
guardrail's real block rate through `ApplyGuardrail`.

**kubectl's current-context is a real work EKS cluster.** Every kubectl call
pins `--context kind-koerber-demo`. Never use current-context: the `bad/`
manifests are deliberately privileged.

**Podman needs `/opt/podman/bin` on PATH** for `krunkit`, or the machine will
not start. Never prune the user's podman volumes or stopped containers.

## State

Controls 1 and 2 are complete and validated in both directions. Control 3 is
written but has not run anywhere. Outstanding: the `ApplyGuardrail` test harness
(injection corpus plus a benign control set, so false positives are reported
too), the five-page design summary, the top-5 risk assessment, and the README.

What the local cluster cannot prove, and the README must say so: IRSA federating
with STS, EKS access entries, CMK envelope encryption of etcd, and control plane
audit logs reaching CloudWatch.
