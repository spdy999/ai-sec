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

## Commands

```bash
make demo             # full presentation walkthrough: pass, then fail, then verdict
make ci               # the gate chain the pipeline enforces (fmt, validate, both policy runs)
make plan             # render the Terraform graph to plan.json, offline
make policy           # secure module must pass every rule
make policy-negative  # insecure fixture must FAIL; a clean run here is itself a failure
make clean            # remove generated plan artefacts
```

Run a single policy file against a rendered plan:

```bash
conftest test --policy controls/policy/iam.rego --all-namespaces controls/terraform/plan.json
```

Requires `terraform` and `conftest`. Everything runs locally with no AWS
account and no credentials.

## Architecture

Three security controls, each validated by proving it rejects bad input, not
merely that it accepts good input.

| Path | Control |
|---|---|
| `controls/terraform/` | The platform itself: KMS CMK, RAG bucket, Bedrock guardrail, IRSA role, private endpoints, vector store |
| `controls/policy/` | Policy-as-code gate (Rego), run by conftest against the rendered plan |
| `controls/terraform/fixtures/insecure/` | Deliberately broken module that the gate must reject |

The diagrams in the Drive folder are backed by real resource addresses in
`controls/terraform/`, so the picture and the code stay in sync.

## Things that will bite you

**Offline plan needs mock credentials.** The AWS provider resolves credentials
during `plan` even with every `skip_*` flag set. `providers.tf` passes
`access_key`/`secret_key` when `var.offline_plan` is true. Without them the plan
fails with `No valid credential sources found`.

**No `data` sources that call AWS.** Account ID, VPC, subnet and OIDC values are
passed as variables precisely so `plan` never contacts AWS.
`aws_iam_policy_document` is fine — it renders client-side.

**Unknown values are not missing values.** Terraform puts attributes it cannot
resolve until apply into `resource_changes[].change.after_unknown`, not into
`planned_values`. A CMK ARN produced by another resource therefore looks
identical to no encryption at all. Use `lib.unknown_at(address, path)` in any
rule that checks an attribute which may be a cross-resource reference — three
false positives came from missing this.

**The negative test is the real test.** `make policy-negative` inverts the exit
code: conftest passing on the insecure fixture means the gate is broken. Any new
rule should be proven to fire there.

**Governance lists live in `controls/policy/lib.rego`**, not in the module they
govern — `approved_model_ids` and `eu_regions` are owned by security, so a team
cannot approve a new model by editing its own Terraform.

**Bedrock guardrails are configured in Terraform, not reimplemented in code.**
Prompt-attack filtering, PII entities, regex masking and denied topics are all
`aws_bedrock_guardrail` config. Custom code exists only for identity-aware
authorization (who may see which documents, who may call which tool) and for
testing the guardrail's real block rate via the `ApplyGuardrail` API.
