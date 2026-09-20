# bedrock-logging

Every prompt and every response, written to CloudWatch, encrypted with the CMK,
retained for a bounded period.

This is the module that makes incident response possible. Without it, "did the
assistant leak the salary table in March?" has no answer. With it, the question
is a log query.

It is also the module with a real tension in it. Prompt and response text is
confidential — that is why it is CMK-encrypted and why retention is bounded
rather than infinite. Data minimisation and auditability pull in opposite
directions here, and `retention_in_days` is where that trade-off is written
down. Image payloads are deliberately not delivered.
