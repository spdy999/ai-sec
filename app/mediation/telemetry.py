"""Security events, to wherever the SIEM subscribes.

One line of JSON per request. Who asked, which documents were returned, whether
the guardrail intervened -- never the question or the answer. A prompt log is a
copy of every sensitive thing anyone typed, held somewhere with weaker controls
than the source, and it is the first thing an attacker reads.

Where the line goes is the provider's business: a CloudWatch log group under
Bedrock, stdout under the local runtime. What is in it is this module's
business, and it is the same either way.
"""

from . import providers


def record(event: dict) -> None:
    providers.log_event(event)
