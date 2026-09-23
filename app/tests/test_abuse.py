"""The detection has to discriminate, not just fire.

An alarm that goes off whenever the fleet is noisy is not a detection, it is a
traffic meter -- and the aggregate metric filter this replaces was exactly
that. So the test that matters is the negative one: the same number of
guardrail interventions, spread across different callers, must produce nothing.

Run offline, no AWS: `make detection-test`.
"""

import os
import pathlib
import sys

# config.py reads its environment at import and refuses to start
# half-configured. The local provider is the cheap one to satisfy, and none of
# it is reached -- abuse.py imports config and nothing else.
os.environ.setdefault("MODEL_PROVIDER", "local")
for _name, _value in {
    "OLLAMA_ENDPOINT": "http://localhost:11434",
    "GUARD_ENDPOINT": "http://localhost:8000",
    "VECTOR_USERNAME": "test",
    "VECTOR_PASSWORD": "test",
    "VECTOR_COLLECTION_ENDPOINT": "http://localhost:9200",
    "IDENTITY_TOKEN_SECRET": "test",
    "ABUSE_WINDOW_SECONDS": "60",
    "ABUSE_THRESHOLD": "3",
    "ABUSE_BLOCK_SECONDS": "300",
}.items():
    os.environ.setdefault(_name, _value)

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))

from app.mediation import abuse  # noqa: E402

_FAILURES: list[str] = []


def check(description: str, actual, expected) -> None:
    if actual == expected:
        print(f"  pass  {description}")
    else:
        print(f"  FAIL  {description}: expected {expected!r}, got {actual!r}")
        _FAILURES.append(description)


print("one subject crossing the threshold must be detected and paused")
abuse.reset()
verdicts = [abuse.record_intervention("mallory") for _ in range(3)]
check("nothing on the first intervention", verdicts[0].crossed, False)
check("nothing on the second", verdicts[1].crossed, False)
check("detected on the third", verdicts[2].crossed, True)
check("subject is then refused", abuse.check("mallory").refused, True)
check("an untouched subject is not", abuse.check("alice").refused, False)

print("")
print("the same volume spread across callers must produce nothing")
abuse.reset()
spread = [abuse.record_intervention(who) for who in ("alice", "bob", "carol", "dave", "erin")]
check("five callers, five interventions, no detection", [v.crossed for v in spread], [False] * 5)
check("none of them is refused", [abuse.check(w).refused for w in ("alice", "bob", "carol")], [False] * 3)

print("")
print("one incident is one event, not one per request afterwards")
abuse.reset()
for _ in range(3):
    abuse.record_intervention("mallory")
later = [abuse.record_intervention("mallory") for _ in range(4)]
check("no repeat detection while already paused", [v.crossed for v in later], [False] * 4)

print("")
if _FAILURES:
    print(f"detection test: {len(_FAILURES)} failure(s)")
    sys.exit(1)

print("detection test: one caller at the threshold is detected; five callers below it are not")
