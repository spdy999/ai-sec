# security-alerting

Metric filters, alarms and two SNS topics over the log groups the platform
already writes.

Logging and detection are different controls, and only the first was built
first. CloudTrail records every model invocation and every guardrail
evaluation; the mediation service writes one structured event per request. None
of that raises a hand. This module is the part that does.

Four signals, each the observable form of a risk rather than a metric
CloudWatch happened to offer. Severity is the routing decision: high means an
identity is doing something it should not and somebody looks now, low means a
number moved and somebody should understand why this week.

| Alarm | Severity | Reads | Fires on |
|---|---|---|---|
| `subject-guardrail-abuse` | high | mediation telemetry | **one identity** crossing the intervention threshold — and already paused by the service |
| `authorization-refusals` | high | mediation telemetry | repeated token refusals — a forged, expired or replayed token |
| `bedrock-access-denied` | high | the trail | a principal refused a Bedrock call, which the authorised path never is |
| `guardrail-interventions` | low | mediation telemetry | fleet-wide blocks elevated — a campaign, or a changed prompt. Not a page |

**Why the attribution happens in the service and not here.** A CloudWatch alarm
binds to a fixed metric identity, so "any one of N callers crossed a threshold"
needs either one alarm per caller — a Terraform change to onboard a user — or a
`SEARCH` expression, which `PutMetricAlarm` rejects outright with *"SEARCH is
not supported on Metric Alarms"*. Summing across everyone is what is left, and
it cannot tell five people blocked once each from one person blocked five
times. The mediation service is the only component holding an authenticated
subject, so it counts per subject and emits one event when one of them crosses.
Counting *that* event needs no dimension: one filter, one alarm, any number of
users. `make detection-test` proves the discrimination, and the half that
matters is the negative half — the same volume spread across five callers
produces nothing.

Crossing also pauses that subject, so the counter that notices is the counter
that contains. The pause is per pod and in memory: two replicas mean a caller
spreading requests evenly needs twice the threshold, and a rollout clears it.
That degrades to slower detection, never to a missed refusal, which is why
there is no shared store on the request path.

Each filter sets `default_value = 0`, so an alarm has a datapoint in a quiet
period rather than sitting in `INSUFFICIENT_DATA` and reading as healthy.
`treat_missing_data` is `missing` rather than `notBreaching` for the same
reason in the other direction: with a zero emitted on every evaluation, absent
data means the log group stopped being written to at all, and that is worth
knowing.

The thresholds are deliberately above one. A single guardrail block is the
control working as designed; paging on it teaches people to ignore the alert.
`subject-guardrail-abuse` is the exception at one, because the service has
already applied the threshold before it writes the event.

Each detection carries its own period. The two subject-level telemetry alarms
sum over 60 seconds, because the service writes those events synchronously and
a detection nobody can watch change state is one nobody trusts. The
trail-sourced alarm keeps 300: CloudTrail delivers on its own five to fifteen
minute schedule, so a shorter window there buys nothing and only makes the
alarm flap. The fleet-wide one keeps 300 as well — it is a trend, and a
one-minute view of a trend is noise.

Every alarm's `alarm_description` names a section of `docs/RUNBOOK.md`, because
the description is the only context that travels in the SNS payload. An alert
that explains the signal but not the response is half a detection.

**The email subscription needs a human.** AWS sends a confirmation link and
delivers nothing until it is clicked, while Terraform reports the subscription
as created. A green apply is not evidence the alert arrives — confirm it, then
`aws sns list-subscriptions-by-topic` and check the ARN is not
`PendingConfirmation`.

**The queue does not.** Both topics also deliver to one SQS queue, and a
same-account subscription confirms itself. That is the provable half of the
notification path: `receive-message` printing the alarm JSON shows the message
was produced, routed and delivered, where an inbox shows only that nothing
arrived. On this account nothing ever did, twice, including from a plain
unencrypted topic created by hand as a control — undiagnosed, and the reason
the queue exists. Messages are kept a day; the trail and the log groups are the
record, this is evidence for the first minutes of an investigation.

The topics are encrypted with the platform CMK, so that key's policy must name
`cloudwatch.amazonaws.com`: an alarm publishes as the service rather than as
the account, and without the grant the alarm transitions and the message is
never delivered. The queue is encrypted with the same key, which adds
`sns.amazonaws.com` to that list for the same reason one step further along —
without it the subscription is created, the alarm fires, and the queue stays
empty with nothing logged to say why.
