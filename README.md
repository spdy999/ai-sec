# Secure enterprise GenAI platform — control implementation

An internal RAG assistant on AWS Bedrock and EKS, implemented as infrastructure
code with the security controls enforced by a policy gate rather than described
in a document.

The policy gate runs offline and free: `terraform plan` renders the
infrastructure graph with mock credentials, and the policy engine reads that
graph as a file — no AWS account touched for CI.

The demo itself deploys for real. `terraform apply` runs against a real AWS
account in `eu-central-1`, at the tuned cost defaults in
`controls/terraform/README.md` (roughly $17/day, mostly OpenSearch
Serverless).

```bash
make demo   # the walkthrough: plan, pass, fail, coverage   (~15s)
make ci     # the gate chain the pipeline enforces
```

## What is here

```
controls/terraform/
  eks-platform/       root: where code runs   - VPC, EKS, nodes, endpoints, jump host, registry
  bedrock-ai/         root: what code does    - Bedrock, guardrail, corpus, vectors, identity
  modules/            thirteen reusable modules, each with its own README
  fixtures/insecure/  deliberately broken config the gate must reject
controls/policy/      76 Rego rules, applied to Terraform plans AND Kubernetes YAML
controls/kubernetes/  base manifests, Kyverno policies, and manifests that must be refused
app/                  the only custom code: the mediation service and its React front-end
.github/workflows/    the CI gate chain, mirroring make ci
```

The two Terraform roots are split for a policy reason, not only an ownership
one. Merged, the cluster's OIDC issuer URL is unknown at plan time, which makes
the whole IRSA trust policy unknown, which makes the rule that checks it stop
firing silently. A control that cannot see its input is not a control.

## What is proven, and how

Every control is validated by proving it **rejects** bad input, never only that
it accepts good input.

| Claim | Proof | Command |
|---|---|---|
| Both layers satisfy every rule | 76 rules, 0 violations | `make policy` |
| The gate refuses insecure infrastructure | 60 violations found in the fixture | `make policy-negative` |
| The gate refuses insecure workloads | 29 violations found in `bad/` | `make policy-k8s-negative` |
| No rule is decorative | 72 of 76 rules proven to fire; 4 exempt, each named | `make policy-coverage` |
| A real cluster enforces admission | four manifests refused by the API server | `make k8s-demo` |
| Default-deny egress actually blocks | a packet sent before and after the policy | `make netpol-proof` |

The coverage gate is the one worth explaining. A rule that has never rejected
anything has not been tested, and a Rego rule that inspects the wrong path
passes silently forever. `make policy-coverage` walks every `deny` in the policy
directory and fails the build unless that rule's message appears in the output
of a negative fixture.

Four rules are exempt and the exemption is itself checked — if one ever does
fire, the build fails as stale. Each is the "present but misconfigured" half of
a pair whose other half is "absent entirely": a plan cannot simultaneously have
no flow log and have one with the wrong traffic type. They are covered by
inspection of their twin.

## What the local cluster cannot prove

A kind cluster on a laptop is not EKS. These controls are implemented in
Terraform and reviewed as code, but nothing here executes them:

- **IRSA federating with STS.** The projected token and the audience are real in
  the manifests; the exchange for AWS credentials needs a real OIDC provider.
- **EKS access entries.** `authentication_mode = "API"` removes the aws-auth
  ConfigMap path. kind has no equivalent.
- **CMK envelope encryption of etcd.** `encryption_config` over `secrets` is a
  managed control plane feature.
- **Control plane audit logs reaching CloudWatch.** The log types are enabled in
  Terraform; the delivery is AWS-side.

Said plainly because a reviewer will ask, and the honest answer is shorter than
the evasive one.

## Requirements

`terraform`, `conftest`, `jq`, `python3`. The live cluster targets additionally
need `kind` (0.33+), `kubectl`, `helm` and a running podman machine.
`make plan`, `make policy` and `make ci` need no AWS account — mock
credentials only. A real `terraform apply` needs a real AWS account with
Bedrock model access enabled in-region, and incurs the cost above.

## Note

Implementation artefacts for a take-home assignment. All sample data is
synthetic; the account IDs, OIDC issuers and employee identifiers in this repo
are placeholders and refer to nothing.
