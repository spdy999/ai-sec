# Infrastructure as code

Two root modules and ten reusable modules. Nothing here is deployed; every
target renders offline with mock credentials and is read by the policy gate as
a file.

```
ai-platform/          root: Bedrock, guardrail, corpus, vectors, workload identity
platform/             root: VPC, EKS, nodes, endpoints
modules/              the reusable pieces both roots compose
fixtures/insecure/    deliberately broken config the gate must reject
```

## Why two roots

Different owners, different lifecycles, different blast radius. The platform
team owns the cluster and the network; the AI team owns the model, the
guardrail and the data. Values flow one way — platform outputs become AI layer
variables, never the reverse.

There is also a policy reason. Merged into one root, the cluster's OIDC issuer
URL would be unknown until apply, which makes the whole IRSA trust policy
unknown, which makes the rule that checks it stop firing — silently. A rule that
quietly passes is worse than one that quietly fails. Splitting the roots keeps
every value the gate inspects a concrete string at plan time.

## The modules

| Module | What it is | The control that matters |
|---|---|---|
| `encryption-key` | Customer-managed KMS key | Rotation on; used twice so platform and AI keys are separate |
| `network` | VPC, private subnets, flow logs | No internet gateway, no NAT, no default route |
| `vpc-endpoints` | Endpoint security group and endpoints | Per-endpoint policy: what may be done *through this path* |
| `eks-cluster` | Control plane, OIDC provider, access | Private API, CMK-encrypted Secrets, audit logs, no bootstrap admin |
| `eks-nodes` | Launch template and node group | IMDSv2 required, hop limit 1 |
| `rag-documents` | Source corpus bucket | Unencrypted uploads denied by bucket policy; versioned for poisoning rollback |
| `vector-store` | OpenSearch Serverless collection | `AllowFromPublic = false`, CMK, VPC endpoint only |
| `bedrock-guardrail` | Prompt-attack filter, PII, denied topics | Enforced server-side, so bypassing the app does not bypass it |
| `bedrock-logging` | Invocation and telemetry log groups | Every prompt and response, encrypted, bounded retention |
| `workload-identity` | The IRSA role | `StringEquals` on `sub`; model calls denied without the guardrail attached |

Each module has a README explaining what it defends against. Read those before
the code.

## Cycles, and where they were broken

Terraform resolves dependencies per resource inside a module but per module
across them, so two splits that read naturally would deadlock:

- **The key and the role.** The key policy wanted the role ARN; the role policy
  wanted the bucket; the bucket wanted the key. Fixed by granting the workload
  key access through its own IAM policy, scoped with `kms:ViaService`, rather
  than in the key policy.
- **The node and endpoint security groups.** Each needs the other's ID. The
  cluster and node groups are created together in `eks-cluster`, and the single
  rule joining nodes to endpoints is wired in the root module, where both are
  known.

Both are visible in the code with comments saying why.

## Running it

```bash
make plan     # render both layers offline
make policy   # both layers must pass all 47 rules
make demo     # the presentation walkthrough
```
