# bedrock-logging

A CloudTrail recording who invoked which model and how every guardrail ruled,
delivered to S3 and mirrored into a CMK-encrypted CloudWatch log group with
bounded retention. Plus the log group the mediation service writes its own
security telemetry to.

This is the module that makes incident response possible. Without it, "who
asked the assistant about the salary table in March, and did the guardrail stop
it?" has no answer. With it, the question is a log query.

## Why not model invocation logging

It was, until AWS refused the call on this account:

```
ValidationException: Your account is not authorized to perform this action.
Please create a support case with details about your use case.
```

That refusal is account-level rather than IAM. The way to tell the difference
is to make the same call with account administrator credentials: an IAM problem
succeeds, this one fails identically.

CloudTrail turns out to be the better instrument for this design anyway.

| | recorded by |
|---|---|
| `InvokeModel`, `Converse`, and their streaming forms | CloudTrail management events, on by default |
| `ApplyGuardrail`, including the evaluations run during an invocation | CloudTrail data events on `AWS::Bedrock::Guardrail` |
| the prompt and the completion text | nothing, deliberately |

The guardrail data event carries the verdict, the filter that produced it and
its confidence. That is the security signal; the prompt text is not.

## The tension, and where it is now resolved

The old configuration set `text_data_delivery_enabled = true`, which built a
copy of every question anyone asked into a log group. `app/mediation/telemetry.py`
refuses to do that, and says why: a prompt log is a copy of every sensitive
thing anyone typed, held somewhere with weaker controls than the source, and it
is the first thing an attacker reads. The two halves of the platform disagreed
with each other. They no longer do.

What is given up is replay — after an incident you can see that a question was
asked, by whom, against which model, and whether the guardrail intervened, but
not what the question said. `retention_in_days` now bounds metadata rather than
content, which makes it a much cheaper number to argue about.

## Two details that are not obvious

`enable_log_file_validation` is on. Without digest files, an audit trail is
whatever the last person with write access says it is.

The trail is single-region. A multi-region trail would collect events from
regions outside the EU allow-list into this account's log store, which is the
residency boundary the platform exists to hold.
