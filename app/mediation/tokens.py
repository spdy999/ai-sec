"""Mint a demo identity token.

Deliberately a separate operator tool rather than an endpoint. A service that
issues its own identity tokens has no authentication, only ceremony.

    python -m mediation.tokens alice --groups finance-team
"""

import argparse
import datetime as dt
import os

import jwt


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("subject")
    parser.add_argument("--groups", nargs="*", default=[])
    parser.add_argument("--minutes", type=int, default=60)
    parser.add_argument("--issuer", default=os.environ.get("IDENTITY_TOKEN_ISSUER", "genai-assistant-demo"))
    args = parser.parse_args()

    secret = os.environ.get("IDENTITY_TOKEN_SECRET", "")
    if not secret:
        raise SystemExit("IDENTITY_TOKEN_SECRET is not set")

    now = dt.datetime.now(tz=dt.timezone.utc)

    print(
        jwt.encode(
            {
                "sub": args.subject,
                "groups": args.groups,
                "iss": args.issuer,
                "iat": now,
                "exp": now + dt.timedelta(minutes=args.minutes),
            },
            secret,
            algorithm="HS256",
        )
    )


if __name__ == "__main__":
    main()
