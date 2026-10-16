# security-alerting

Metric filters, alarms and an SNS topic over the log groups the platform
already writes.

Logging and detection are different controls, and only the first was built
first. CloudTrail records every model invocation and every guardrail
evaluation; the mediation service writes one structured event per request. None
of that raises a hand. This module is the part that does.

Three signals, each the observable form of a risk rather than a metric
CloudWatch happened to offer:

| Alarm | Reads | Fires on |
|---|---|---|
| `guardrail-interventions` | mediation telemetry | a burst of blocks — someone working through injection phrasings |
| `authorization-refusals` | mediation telemetry | repeated token refusals — a forged, expired or replayed token |
| `bedrock-access-denied` | the trail | a principal refused a Bedrock call, which the authorised path never is |

Each filter sets `default_value = 0`, so an alarm has a datapoint in a quiet
period rather than sitting in `INSUFFICIENT_DATA` and reading as healthy.
`treat_missing_data` is `missing` rather than `notBreaching` for the same
reason in the other direction: with a zero emitted on every evaluation, absent
data means the log group stopped being written to at all, and that is worth
knowing.

The thresholds are deliberately above one. A single guardrail block is the
control working as designed; paging on it teaches people to ignore the alert.

Each detection carries its own period. The two telemetry alarms sum over 60
seconds, because the service writes those events synchronously and a detection
nobody can watch change state is one nobody trusts. The trail-sourced alarm
keeps 300: CloudTrail delivers on its own five to fifteen minute schedule, so a
shorter window there buys nothing and only makes the alarm flap.

**The email subscription needs a human.** AWS sends a confirmation link and
delivers nothing until it is clicked, while Terraform reports the subscription
as created. A green apply is not evidence the alert arrives — confirm it, then
`aws sns list-subscriptions-by-topic` and check the ARN is not
`PendingConfirmation`.

**The queue does not.** The topic also delivers to an SQS queue, and a
same-account subscription confirms itself. That is the provable half of the
notification path: `receive-message` printing the alarm JSON shows the message
was produced, routed and delivered, where an inbox shows only that nothing
arrived. The email subscription on this account is confirmed and does deliver,
but it took two rebuilds before a confirmation mail was received at all — which
is the reason the queue exists and stays the path the demo checks. Messages are
kept a day; the trail and the log groups are the
record, this is evidence for the first minutes of an investigation.

The topic is encrypted with the platform CMK, so that key's policy must name
`cloudwatch.amazonaws.com`: an alarm publishes as the service rather than as
the account, and without the grant the alarm transitions and the message is
never delivered. The queue is encrypted with the same key, which adds
`sns.amazonaws.com` to that list for the same reason one step further along —
without it the subscription is created, the alarm fires, and the queue stays
empty with nothing logged to say why.
