"""Mint a demo identity token.

Deliberately a separate operator tool rather than an endpoint. A service that
issues its own identity tokens has no authentication, only ceremony.

    python -m mediation.tokens alice --groups finance-team

Run it inside the pod. The signing key's resource policy names the workload
role and the ingestion role and denies every other principal, so a laptop
holding administrator credentials still cannot read it -- but the pod already
can, with its own IRSA token:

    kubectl exec deploy/genai-mediation -n genai-platform -- \
        python -m mediation.tokens alice --groups all-staff
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

    # Inside the pod the key arrives as an ARN rather than a value, because
    # nothing writes the material into the environment. Resolving it here is
    # what lets this run where the credential to read it already exists.
    secret = os.environ.get("IDENTITY_TOKEN_SECRET", "")
    if not secret:
        arn = os.environ.get("IDENTITY_SECRET_ARN", "")
        if not arn:
            raise SystemExit("neither IDENTITY_TOKEN_SECRET nor IDENTITY_SECRET_ARN is set")

        from . import secrets

        secret = secrets.secret_string(arn, os.environ.get("AWS_REGION", "eu-central-1"))

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
