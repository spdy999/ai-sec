"""Per-subject guardrail abuse detection.

CloudWatch cannot do this part. An alarm binds to a fixed metric identity, so
"any one of N callers crossed a threshold" needs either one alarm per caller --
a Terraform change to onboard a user -- or a SEARCH expression, which
PutMetricAlarm rejects outright with "SEARCH is not supported on Metric
Alarms". Summing interventions across everyone is what is left, and it cannot
tell five people each blocked once from one person trying six phrasings.

This service is the only component holding an authenticated subject, so the
decision belongs here. It counts per subject and emits one event when a single
subject crosses the threshold. A metric filter counts that event -- no
dimensions, threshold 1, one alarm for any number of users.

Crossing also refuses the subject's next requests for a cooldown. The counter
that notices is the counter that contains, which makes this a preventive
control and not only a detective one, and it stops an attacker spending the
account's Bedrock budget while somebody reads the alert.

State is per pod and in memory. Two replicas means a caller spreading requests
evenly across both needs 2N interventions rather than N, and a restart clears
the window. Both are documented in RUNBOOK.md rather than fixed with a shared
store: the failure mode is a slower detection, never a missed refusal, and a
round trip to Redis on the request path buys less than it costs.
"""

import threading
import time
from dataclasses import dataclass

from . import config

# Subjects tracked at once. Only authenticated callers reach this module -- a
# forged token is refused before it -- so this is a bound on a real user
# population rather than on attacker input. Past it the coldest subject is
# dropped, which loses a partial window and never loses a block.
_MAX_TRACKED_SUBJECTS = 10_000

_lock = threading.Lock()

# subject -> list of intervention timestamps inside the window
_interventions: dict[str, list[float]] = {}

# subject -> monotonic time the refusal expires
_blocked_until: dict[str, float] = {}


@dataclass(frozen=True)
class Verdict:
    """What the caller should do about this subject, and what to log."""

    refused: bool
    crossed: bool
    count: int
    retry_after_seconds: int


def _prune(now: float) -> None:
    """Called with the lock held."""
    for subject in list(_blocked_until):
        if _blocked_until[subject] <= now:
            del _blocked_until[subject]

    for subject in list(_interventions):
        fresh = [t for t in _interventions[subject] if t > now - config.ABUSE_WINDOW_SECONDS]
        if fresh:
            _interventions[subject] = fresh
        else:
            del _interventions[subject]

    if len(_interventions) > _MAX_TRACKED_SUBJECTS:
        coldest = sorted(_interventions, key=lambda s: _interventions[s][-1])
        for subject in coldest[: len(_interventions) - _MAX_TRACKED_SUBJECTS]:
            del _interventions[subject]


def check(subject: str) -> Verdict:
    """Is this subject currently refused? Called before any retrieval."""
    now = time.monotonic()
    with _lock:
        expires = _blocked_until.get(subject)
        if expires is None or expires <= now:
            return Verdict(refused=False, crossed=False, count=0, retry_after_seconds=0)

        return Verdict(
            refused=True,
            crossed=False,
            count=len(_interventions.get(subject, [])),
            retry_after_seconds=max(1, int(expires - now)),
        )


def record_intervention(subject: str) -> Verdict:
    """Count one guardrail intervention against this subject.

    `crossed` is true only on the request that crosses, not on every request
    afterwards, so the alarm counts incidents rather than the length of one.
    """
    now = time.monotonic()
    with _lock:
        _prune(now)

        hits = _interventions.setdefault(subject, [])
        hits.append(now)
        count = len(hits)

        if count < config.ABUSE_THRESHOLD or subject in _blocked_until:
            return Verdict(refused=False, crossed=False, count=count, retry_after_seconds=0)

        _blocked_until[subject] = now + config.ABUSE_BLOCK_SECONDS
        return Verdict(
            refused=False,
            crossed=True,
            count=count,
            retry_after_seconds=config.ABUSE_BLOCK_SECONDS,
        )


def reset() -> None:
    """Drop all state. For tests and for the negative-test harness."""
    with _lock:
        _interventions.clear()
        _blocked_until.clear()
