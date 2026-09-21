"""Security events, to the log group the SIEM subscribes to.

One line of JSON per request. Who asked, which documents were returned, whether
the guardrail intervened -- never the question or the answer. A prompt log is a
copy of every sensitive thing anyone typed, held somewhere with weaker controls
than the source, and it is the first thing an attacker reads.
"""

import json
import time
import uuid

from . import aws, config

_stream = f"mediation-{uuid.uuid4().hex[:12]}"
_ready = False


def _ensure_stream() -> bool:
    global _ready
    if _ready:
        return True
    if not config.TELEMETRY_LOG_GROUP:
        return False

    try:
        aws.logs.create_log_stream(
            logGroupName=config.TELEMETRY_LOG_GROUP, logStreamName=_stream
        )
    except aws.logs.exceptions.ResourceAlreadyExistsException:
        pass
    except Exception:
        # Telemetry must never be the reason a request fails. A dropped event is
        # a monitoring gap; a 500 here would be an outage.
        return False

    _ready = True
    return True


def record(event: dict) -> None:
    if not _ensure_stream():
        return

    try:
        aws.logs.put_log_events(
            logGroupName=config.TELEMETRY_LOG_GROUP,
            logStreamName=_stream,
            logEvents=[
                {
                    "timestamp": int(time.time() * 1000),
                    "message": json.dumps(event, separators=(",", ":")),
                }
            ],
        )
    except Exception:
        return
