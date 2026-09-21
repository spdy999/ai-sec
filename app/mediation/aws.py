"""Shared AWS clients.

Credentials come from the projected service account token: the pod exchanges it
for short-lived ones through IRSA, boto3 does that automatically, and there is
no key anywhere on the node to steal.
"""

import boto3
from opensearchpy import AWSV4SignerAuth, OpenSearch, RequestsHttpConnection

from . import config

session = boto3.Session(region_name=config.AWS_REGION)

bedrock = session.client("bedrock-runtime", region_name=config.AWS_REGION)
logs = session.client("logs", region_name=config.AWS_REGION)


def opensearch_client(endpoint: str | None = None) -> OpenSearch:
    """A signed client for OpenSearch Serverless.

    The service name is `aoss`, not `es`. Signing as `es` produces a 403 whose
    message does not mention signing, and the usual next move is to widen the
    IAM policy, which does not help.
    """
    host = (endpoint or config.VECTOR_ENDPOINT).replace("https://", "")

    return OpenSearch(
        hosts=[{"host": host, "port": 443}],
        http_auth=AWSV4SignerAuth(session.get_credentials(), config.AWS_REGION, "aoss"),
        use_ssl=True,
        verify_certs=True,
        connection_class=RequestsHttpConnection,
        pool_maxsize=20,
    )
