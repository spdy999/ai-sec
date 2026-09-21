"""The platform as designed: Bedrock, Bedrock Guardrails, OpenSearch Serverless.

Credentials come from the projected service account token. The pod exchanges it
for short-lived ones through IRSA, boto3 does that automatically, and there is
no key anywhere on the node to steal.
"""

import json
import time
import uuid

import boto3
from opensearchpy import AWSV4SignerAuth, OpenSearch, RequestsHttpConnection

from .. import config

session = boto3.Session(region_name=config.AWS_REGION)

_bedrock = session.client("bedrock-runtime", region_name=config.AWS_REGION)
_logs = session.client("logs", region_name=config.AWS_REGION)


def embed(text: str) -> list[float]:
    response = _bedrock.invoke_model(
        modelId=config.EMBEDDING_MODEL_ID,
        body=json.dumps({"inputText": text}),
    )
    return json.loads(response["body"].read())["embedding"]


def generate(prompt: str) -> dict:
    """Invoke the approved model behind the guardrail.

    `guardrailIdentifier` is not a convenience. The IRSA policy conditions
    `bedrock:InvokeModel` on `bedrock:GuardrailIdentifier`, so an unguarded call
    from this pod is refused by IAM before it reaches Bedrock. Removing the
    argument does not quietly weaken the service, it stops it working.
    """
    response = _bedrock.invoke_model(
        modelId=config.CHAT_MODEL_ID,
        guardrailIdentifier=config.GUARDRAIL_ID,
        guardrailVersion=config.GUARDRAIL_VERSION,
        trace="ENABLED",
        body=json.dumps(
            {
                "anthropic_version": "bedrock-2023-05-31",
                "max_tokens": 800,
                "temperature": 0,
                "messages": [{"role": "user", "content": prompt}],
            }
        ),
    )

    payload = json.loads(response["body"].read())

    # Bedrock replaces the model's output with its own when the guardrail
    # intervenes, and says so in amazon-bedrock-guardrailAction.
    intervened = payload.get("amazon-bedrock-guardrailAction") == "INTERVENED"

    blocks = payload.get("content", [])
    text = "".join(b.get("text", "") for b in blocks if b.get("type") == "text")

    return {
        "text": text or "The guardrail blocked this response.",
        "guardrail_intervened": intervened,
        "stop_reason": payload.get("stop_reason"),
    }


def vector_client(endpoint: str | None = None) -> OpenSearch:
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


_stream = f"mediation-{uuid.uuid4().hex[:12]}"
_stream_ready = False


def _ensure_stream() -> bool:
    global _stream_ready
    if _stream_ready:
        return True
    if not config.TELEMETRY_LOG_GROUP:
        return False

    try:
        _logs.create_log_stream(
            logGroupName=config.TELEMETRY_LOG_GROUP, logStreamName=_stream
        )
    except _logs.exceptions.ResourceAlreadyExistsException:
        pass
    except Exception:
        # Telemetry must never be the reason a request fails. A dropped event is
        # a monitoring gap; a 500 here would be an outage.
        return False

    _stream_ready = True
    return True


def log_event(event: dict) -> None:
    """One security event to the log group the SIEM subscribes to."""
    if not _ensure_stream():
        return

    try:
        _logs.put_log_events(
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
