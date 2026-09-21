# Runbook

Operational how-to for this repo. `README.md` explains what the controls
prove; this explains what to type, in what order, and what to do when it
breaks. See `CLAUDE.md` for the assignment context and locked decisions.

## 1. Prerequisites

| Tool | Needed for | Notes |
|---|---|---|
| `terraform` | plan, policy, everything | |
| `conftest` | policy gates | |
| `jq` | `make plan` resource counts, gate output | |
| `python3` | `make policy-coverage` | |
| `kind` 0.33+ | live cluster targets | |
| `kubectl` | live cluster targets | every call pins `--context kind-koerber-demo` |
| `helm` | live cluster targets | Kyverno install |
| `podman` machine, running | live cluster targets | `/opt/podman/bin` must be on `PATH` for `krunkit`, or the machine will not start |

Offline targets (`plan`, `policy`, `ci`) need none of the AWS credentials —
`providers.tf` injects mock keys when `offline_plan = true` (the default).

## 2. Day-to-day: the offline gate loop

No AWS account, no podman, no cost. This is what CI runs and what you run
while editing Terraform or Rego.

```bash
make plan             # render both roots to plan.json
make policy           # both secure layers pass all 70 rules
make policy-negative  # insecure fixture must FAIL (a clean run is a bug)
make policy-k8s       # workload manifests pass
make policy-coverage  # every rule fires against a fixture
make ci               # all of the above, in the order the pipeline runs it
```

`plan.json` files are real file targets keyed on `.tf` mtimes — editing Rego
alone does not re-render a plan; editing a module under
`controls/terraform/modules/` re-renders both roots.

After editing Terraform: `make clean` before `make plan` if a stale
`plan.json` looks wrong (rare — the file-target dependency should catch it).

## 3. Live cluster session

Needs podman running. Order matters — `k8s-demo` depends on `kind-up`.

```bash
make kind-up          # create the kind cluster (podman driver)
make k8s-demo         # apply base manifests + Kyverno, admit the hardened
                       # workload, then throw four bad manifests at the API
                       # server and show each refused
make netpol-proof     # send a packet before and after default-deny egress
make kind-down        # tear down when finished
```

Every `kubectl` call in the Makefile pins `--context kind-koerber-demo`
deliberately — the current-context on this machine is a real work EKS
cluster, and the `bad/` manifests are privileged on purpose. Never run
`kubectl` here without `--context` if you're typing it by hand instead of
through `make`.

**Podman gotcha:** if the machine won't start, check `/opt/podman/bin` is on
`PATH` first before anything else — that's the `krunkit` trap, not a podman
bug. Never prune podman volumes or stopped containers on this machine; they
may not be yours.

## 4. Real AWS deploy (manual — no Makefile target)

This deploys for real, in `eu-central-1`, at roughly $16/day (71% OpenSearch
Serverless). There is no `apply`/`destroy` target on purpose — don't add one
without asking. Roots are separate applies, in order, because `bedrock-ai`
takes `eks-platform`'s VPC/OIDC values as plain variables (not a remote-state
lookup — that's what keeps `plan` credential-free).

```bash
# 1. eks-platform first
terraform -chdir=controls/terraform/eks-platform init
terraform -chdir=controls/terraform/eks-platform apply -var offline_plan=false

# 2. read its outputs
terraform -chdir=controls/terraform/eks-platform output

# 3. bedrock-ai, feeding in the real values from step 2
terraform -chdir=controls/terraform/bedrock-ai apply \
  -var offline_plan=false \
  -var account_id=<real account id> \
  -var vpc_id=<from step 2> \
  -var private_subnet_ids='["<...>","<...>"]' \
  -var eks_oidc_provider_arn=<from step 2> \
  -var eks_oidc_provider_url=<from step 2>
```

**Always `terraform destroy` both roots (bedrock-ai first, then eks-platform)
after a live session.** Nothing here auto-tears-down.

## 5. Presentation demo

Budgeted at three minutes; `make demo` itself runs ~13s and prints 47 lines.
Don't add to it without checking it still earns its place.

```bash
make demo
```

Walks: render offline → both layers pass → insecure fixture fails → insecure
workloads fail → every rule proven to fire. `SHOW=5` truncates negative
output to five examples plus a count; unset (as CI leaves it) for the full
list — `make policy-negative` / `make policy-k8s-negative` alone always show
everything.

## 6. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `plan` fails asking for real AWS creds | ran with `-var offline_plan=false` or unset default, or real `AWS_*` env vars leaking in | offline targets run under `env -u AWS_ACCESS_KEY_ID ...` (`$(NO_AWS)` in the Makefile) — don't override `offline_plan` for offline work |
| A rule checking a cross-resource attribute false-positives | attribute is unresolved at plan time, sitting in `resource_changes[].change.after_unknown`, not `planned_values` | use `lib.unknown_at(address, path)` in the rule |
| A refactor "changed" a plan with no real diff | `terraform show -json` reorders `relevant_attributes` every run | compare `jq -S '{planned_values, resource_changes}'`, not the raw file |
| New rule passes `make policy` but fails `make ci` | `make policy-coverage` requires every rule to fire against a fixture at least once | add/extend a fixture so the rule's message appears in negative output, or add it to the 4-rule exemption list in `controls/policy/coverage.py` with a reason |
| An exempt rule shows up in coverage output | one of the "present but misconfigured" halves in `coverage.py` actually fired | remove it from the exemption list — the gate treats this as stale and fails |
| podman machine won't start | `krunkit` not found | put `/opt/podman/bin` on `PATH` |
| `kubectl` hits the wrong cluster | forgot `--context kind-koerber-demo` | always pin context by hand; never rely on current-context here |
| Merging the two Terraform roots "to simplify" | OIDC issuer URL becomes unknown at plan time in a single root, which makes the IRSA trust policy unknown, which makes its rule stop firing — silently | don't merge them; that split is a policy requirement, not an ownership one |
