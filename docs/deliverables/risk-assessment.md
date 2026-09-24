# Top 5 risks — internal RAG assistant on Bedrock + EKS

Draft, 2026-09-23. Ratings are for the platform as deployed in account
891377211626 (eu-central-1), not for a hypothetical production rollout.
Each risk names the evidence it came from: four of the five were found by
running the platform, not by reviewing it.

---

## R1 — A guardrail can be attached, configured, and scanning nothing

**OWASP LLM01 (prompt injection). Likelihood: high. Impact: high.**

**Component.** The mediation service's call into Bedrock, and the guardrail
attached to it.

**Business impact.** An injection that is answered rather than blocked turns the
assistant into an exfiltration path for whatever the caller's identity can
reach. For an internal assistant over HR and finance documents that is a
reportable disclosure, and the first evidence of it is an answer no log
distinguishes from a legitimate one.

The guardrail carried `PROMPT_ATTACK` at HIGH strength and was correctly
referenced by the application, and every injection still came back
`guardrail_intervened: false`. The requests were refused — by the model's own
judgement, which reads exactly like the control working and is not a control at
all. Bedrock applies the prompt-attack filter only to input the caller marks as
untrusted; `InvokeModel` with the Anthropic Messages body ignores the guard
content tags entirely and returns `amazon-bedrock-guardrailAction: NONE` with
every policy unit at zero, on text that `ApplyGuardrail` blocks at HIGH
confidence.

This is the most important finding in the build: a control that is green on
every dashboard, passes every configuration scan, and does nothing. No policy
rule can catch it, because the Terraform is correct — the defect is in how the
application calls the model.

**Controls now in place.** The service calls `Converse` with the user's
question in its own `guardContent` block; retrieved passages stay outside it, so
a planted injection in a document cannot block the corpus. IAM conditions
`bedrock:InvokeModel` on `bedrock:GuardrailIdentifier`, so an unguarded call
from the workload is refused before it reaches Bedrock. A live injection now
returns `stopReason: guardrail_intervened`.

**Detection.** Every guardrail evaluation is a CloudTrail data event on
`AWS::Bedrock::Guardrail`, recorded with the filter that produced it, so a block
is evidence and not an inference. The mediation service emits
`guardrail_intervened` on each answer to the telemetry log group, and an alarm
fires on a burst of them. The failure mode
this risk describes is detectable only by that pair disagreeing with what the
user sees: a refusal with no intervention recorded is the model being polite,
not a control firing.

**Residual.** Block rate is demonstrated, not measured: there is no test harness
running an injection corpus through `ApplyGuardrail` and tracking the rate over
time, so a regression would show up as an answered injection in production. The
guardrail is also on the Classic content-filter tier by default rather than by
decision.

**Actions.** (1) Build the `ApplyGuardrail` evaluation harness and gate releases
on it. (2) Assert `guardrail_intervened` in an end-to-end test, not only in the
demo. (3) Decide Classic vs Standard tier explicitly and record the reason.

---

## R2 — Entitlement filtering is only as good as the metadata on the documents

**OWASP LLM02 (sensitive information disclosure). Likelihood: medium. Impact: high.**

**Component.** The ingestion path and the audience metadata it writes; the
retrieval query that reads it.

**Business impact.** A salary band, a forecast or a personnel note reaching an
employee not entitled to it. Unlike an injection, this failure is silent on both
sides: the caller sees a normal answer and the platform sees a normal retrieval.

Access control here is not a model behaviour, and deliberately so: the
identity's group claims are matched against the audience recorded on each
passage at ingestion, and non-entitled passages are never retrieval candidates.
This is demonstrable — the same question, the same index, answered for `dana`
and not for `alice`, with the difference visible in the Sources line rather than
in what the model was told to say.

The weakness is upstream of the platform. A document classified wrongly at
ingestion is indexed with the wrong audience and becomes retrievable by the
wrong population, and nothing in the pipeline disputes the classification. The
guardrail will not save that case: PII filters mask identifiers that appear in a
response, they do not decide who was entitled to ask.

**Controls now in place.** Audience metadata is applied at ingestion; the
service filters before generation, not after. The OpenSearch data access policy
grants writes to the ingestion role only — the workload identity has read and
nothing else, which is what makes corpus poisoning through the chat path
impossible rather than merely unlikely. Signing keys for the identity tokens sit
in Secrets Manager under a resource policy that denies every principal but the
workload and ingestion roles, so an administrator on a laptop cannot mint a
token.

**Detection.** Each answer logs the identity, its group claims and the
passages returned, so a retrieval that should not have matched is visible after
the fact. Authorisation refusals are logged as their own event type, and an alarm fires
when several arrive in one period — a forged or replayed token rather than a
user mistyping one.

**Residual.** No automated check that a document's classification matches its
content; no review step between a corpus commit and an index rebuild, and a
corpus push now triggers ingestion automatically.

**Actions.** (1) Require a second approver on changes under the corpus path.
(2) Add a pre-ingestion check that refuses a document with no audience label.
(3) Sample-audit indexed passages against source classification quarterly.

---

## R3 — The delivery pipeline is the highest-privilege identity in the account

**OWASP LLM05 (supply chain). Likelihood: medium. Impact: critical.**

**Component.** The GitHub Actions deploy role, and every layer of the platform
it can rewrite.

**Business impact.** Whoever can merge can change the platform, disable a
control, or destroy the environment. The state deletion described below is the
same blast radius arriving by accident rather than by intent, and recovery took
bucket versioning rather than a backup policy.

A push to `main` applies infrastructure. The role the pipeline assumes holds
`ec2:*`, `eks:*` and `kms:*` — necessary while those resources do not exist yet,
and far wider than any human in the account. Whoever can merge can change the
platform, and on this repository's plan there is no required-reviewer gate to
prevent it.

An automation defect has already demonstrated the blast radius. A cleanup step
running `if: always()` interpolated a variable that an earlier failure had left
unset, so the command became `aws s3 rm --recursive s3://<state bucket>/` with
`|| true` swallowing the result. Every layer's state was deleted. Bucket
versioning is the only reason it was recoverable.

**Controls now in place.** OIDC federation with no stored keys, and a trust
policy pinned to GitHub's ID-qualified subject so a repository rename cannot
transfer trust. IAM actions are scoped by name prefix, `PassRole` is conditioned
on the target service, and two explicit denies stop the role editing its own
trust policy or deleting the state bucket. Both cleanup steps now guard on a
non-empty prefix. Every deployment runs the full policy chain inside the
applying run, against the saved plan that is about to be applied.

**Detection.** CloudTrail covers the role's every API call, and the run log
records the plan that was applied. The state bucket is versioned, which is how
the deletion above was both noticed and reversed.

**Residual.** The deny covers deleting the state *bucket*; it does not cover
deleting the objects in it. The service wildcards are untightened after the
first successful apply. There is no branch protection on this plan.

**Actions.** (1) Deny `s3:DeleteObject` on state prefixes other than the layer
being applied. (2) Replace the service wildcards with the action list a
successful apply actually used. (3) Require review on `main` and a typed
confirmation on teardown (the latter exists).

---

## R4 — EU data residency depends on an inference profile AWS controls

**Likelihood: medium. Impact: high (regulatory).**

**Component.** The cross-region inference profile the chat model is invoked
through, and the IAM and endpoint policies that bound it.

**Business impact.** Employee questions and retrieved document content
processed outside the EU, which is a GDPR transfer question rather than a
security incident — the kind that surfaces in an audit, not in an alert, and
whose remedy is a filing rather than a patch.

Anthropic models in eu-central-1 are invocable only through a cross-region
inference profile. That profile routes to six regions — eu-central-1, eu-west-1,
eu-west-3, eu-north-1, eu-south-1 and eu-south-2 — and the membership is AWS's
to change, not the account's. The configuration named four of them, which was
found as a runtime failure rather than as a compliance finding; two were opt-in
regions the account had not enabled.

All six are in the EU today. The risk is drift: if AWS adds a region to the
profile, inference reaches it as soon as routing decides to, and nothing in the
account announces the change.

**Controls now in place.** IAM grants the foundation-model ARN only within an
explicit region list, so a region outside the list is refused by the account
even if the profile routes there. The VPC endpoint policy pins which model may
be reached. The approved-model list lives in the policy library, not in the
team's own Terraform, and the rule strips the geography prefix so a new model
cannot be approved by prefixing it. CloudTrail is single-region on purpose — a
multi-region trail would pull events from outside the allow-list into this log
store.

**Detection.** CloudTrail records the region each invocation ran in, so
routing outside the allow-list is visible in the trail even when IAM refuses the
call. Nothing watches the profile's membership itself — that is the gap.

**Residual.** No alert fires when the profile's membership changes; the failure
mode is a refused request, discovered by a user.

**Actions.** (1) Scheduled check of `get-inference-profile` membership against
the allow-list, alerting on difference. (2) Record the residency decision and
the six regions in the model governance register.

---

## R5 — The audit trail proves a call happened, not what was asked

**Likelihood: high. Impact: medium.**

**Component.** CloudTrail, the mediation telemetry log group, and the alarms
over both.

**Business impact.** An investigation that can establish who called and whether
the guardrail intervened, but not what was asked. For a disclosure incident that
is the difference between scoping the exposure and estimating it.

Bedrock model invocation logging is refused at account level on this account, so
the trail is CloudTrail: `InvokeModel` and `Converse` as management events, and
`ApplyGuardrail` as a data event that carries the evaluations Bedrock runs
during an invocation — so every guardrail block is recorded together with the
filter that produced it.

Neither carries prompt text. That is a deliberate trade: the mediation service
refuses to log prompts, and logging them would put user questions and retrieved
document content into a second store with a different access model. The cost is
that an investigation into a suspected exfiltration attempt can establish who
called, when, under which identity, and whether the guardrail intervened — but
not what was asked.

**Controls now in place.** Structured security events from the mediation service
to a log group the SIEM subscribes to; CloudTrail data events on the guardrail;
telemetry that fails open so a logging outage never becomes an application
outage.

**Detection.** Three CloudWatch alarms now read those streams and publish to an
SNS topic: a burst of guardrail interventions and a burst of authorisation
refusals, both from the mediation telemetry log group, and any `AccessDenied`
against Bedrock in the trail. Each metric filter emits a zero for a
non-matching event, so a quiet period with traffic is distinguishable from a
service that has stopped logging.

**Residual.** Still no prompt replay for incident response, and no alarm on a
single identity's query volume. The trail-sourced alarm inherits CloudTrail's
delivery latency, five to fifteen minutes, so it is an investigation trigger
rather than a real-time control. Notification reaches a queue, not a person:
routing it to an on-call tool is a subscription away and is not deployed here.

**Actions.** (1) Add a per-identity query-volume alarm, which is what a slow
scripted extraction looks like. (2) Subscribe an on-call tool to the alert
topic, so a notification reaches a person rather than a queue. (3) Decide, with Legal and the DPO,
whether a short-retention prompt store under restricted access is worth the
replay it buys.

---

## Noted, below the top five

**Index rebuild has no safe path.** `--recreate` drops the index before it
rebuilds it, and a corpus commit triggers the rebuild automatically, so a failed
run leaves the assistant answering nothing with no alert. Index into a new name
and swap an alias at the end. Availability, not confidentiality, which is why it
sits here rather than above.

**A manifest can pass every gate and still be refused by the API server**, and a
policy gate reads the manifest rather than what an admission webhook does to it.
Kyverno in the cluster is the second half of that pair and is deployed.
