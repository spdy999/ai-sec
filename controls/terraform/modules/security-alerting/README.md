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

**The email subscription needs a human.** AWS sends a confirmation link and
delivers nothing until it is clicked, while Terraform reports the subscription
as created. A green apply is not evidence the alert arrives — confirm it, then
`aws sns list-subscriptions-by-topic` and check the ARN is not
`PendingConfirmation`.

The topic is encrypted with the platform CMK, so that key's policy must name
`cloudwatch.amazonaws.com`: an alarm publishes as the service rather than as
the account, and without the grant the alarm transitions and the message is
never delivered.
