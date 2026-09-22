"""Secret material, fetched at startup from Secrets Manager.

There is no Kubernetes Secret behind any of this. A Secret is base64, not
encryption: it sits in etcd, it is readable by anyone who can `kubectl get
secret -o yaml` in the namespace, and it appears in the manifest a pipeline
prints. Reading from Secrets Manager instead means the material is encrypted
with the platform CMK, the read is an authenticated API call recorded in
CloudTrail, and the credential that makes it is the pod's own short-lived IRSA
token.

Fetched once, at import, and held in memory. A running pod that loses its
credentials keeps serving; it does not silently start answering without a
signing key.
"""

import json
from functools import lru_cache

import boto3


@lru_cache(maxsize=None)
def _client(region: str):
    return boto3.client("secretsmanager", region_name=region)


def secret_string(arn: str, region: str) -> str:
    """The raw value of a secret. Raises if it cannot be read: a service that
    starts without its signing key would accept every token presented to it."""
    response = _client(region).get_secret_value(SecretId=arn)

    value = response.get("SecretString")
    if not value:
        raise RuntimeError(f"{arn} holds no string value; refusing to start")

    return value


def secret_json(arn: str, region: str) -> dict:
    """A secret whose value is a JSON object, for material that comes in more
    than one piece -- the TLS certificate and its private key."""
    parsed = json.loads(secret_string(arn, region))

    if not isinstance(parsed, dict):
        raise RuntimeError(f"{arn} is not a JSON object; refusing to start")

    return parsed
