"""Who is asking, and what they are entitled to see.

The whole point of the mediation layer. A RAG service that retrieves first and
filters afterwards has already read the document it was not allowed to read,
and a model that has seen a restricted passage will leak it however carefully
the answer is worded. Entitlement therefore belongs in the retrieval query, and
this module is what produces it.
"""

from dataclasses import dataclass

import jwt

from . import config


class IdentityError(Exception):
    """Raised for a missing, malformed, expired or unsigned token."""


@dataclass(frozen=True)
class Caller:
    subject: str
    groups: frozenset[str]

    def __str__(self) -> str:
        return f"{self.subject} ({', '.join(sorted(self.groups)) or 'no groups'})"


def caller_from_authorization(header: str | None) -> Caller:
    """Verify a bearer token and return the identity it asserts.

    Signature, expiry and issuer are all checked. An unverified decode here --
    the `options={"verify_signature": False}` that shows up in a surprising
    number of examples -- would let anyone mint themselves any group.
    """
    if not header or not header.lower().startswith("bearer "):
        raise IdentityError("no bearer token")

    token = header.split(" ", 1)[1].strip()

    try:
        claims = jwt.decode(
            token,
            config.JWT_SECRET,
            algorithms=["HS256"],
            issuer=config.JWT_ISSUER,
            options={"require": ["exp", "sub", "iss"]},
        )
    except jwt.InvalidTokenError as exc:
        raise IdentityError(str(exc)) from exc

    groups = claims.get("groups", [])
    if not isinstance(groups, list) or not all(isinstance(g, str) for g in groups):
        raise IdentityError("groups claim must be a list of strings")

    # Every caller implicitly belongs to all-staff. Documents carrying a
    # narrower audience are reachable only by naming that audience.
    return Caller(subject=claims["sub"], groups=frozenset(groups) | {"all-staff"})
