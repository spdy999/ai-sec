"""The same architecture with no cloud account.

Three substitutions, each chosen so the control it carries survives rather than
becoming a claim:

  Bedrock            -> Ollama, running on the operator's machine. Real
                        inference, real latency, no mock.

  Bedrock Guardrails -> a separate guard service running Llama Guard. The
                        mediation pod has no NetworkPolicy route to the model;
                        its only egress to inference is the guard. So the
                        application still cannot choose to skip the guardrail --
                        the mechanism changed from IAM to NetworkPolicy, the
                        property did not.

  OpenSearch         -> OpenSearch in-cluster, same engine. retrieval.py is
  Serverless            byte-for-byte the same code, including the entitlement
                        filter inside the kNN query, because the query language
                        is the same one. The write separation survives too: the
                        service authenticates as a read-only user on the index
                        and ingestion runs as a different, write-capable one.

What does not survive is honest to say out loud, and belongs in the risk
assessment rather than buried here: there is no KMS envelope encryption, and
the audit trail is emitted by the application instead of by the platform. A
compromised application can stop writing its own logs. CloudTrail cannot be
silenced by the thing it is watching.
"""

import json
import sys

import requests
from opensearchpy import OpenSearch

from .. import config

_timeout = config.LOCAL_TIMEOUT_SECONDS


def embed(text: str) -> list[float]:
    response = requests.post(
        f"{config.OLLAMA_ENDPOINT}/api/embeddings",
        json={"model": config.EMBEDDING_MODEL_ID, "prompt": text},
        timeout=_timeout,
    )
    response.raise_for_status()
    return response.json()["embedding"]


def generate(system: str, context: str, question: str) -> dict:
    """Ask the guard service, which is the only route to the model.

    Note what is *not* here: no Ollama chat endpoint. The mediation pod cannot
    reach it -- NetworkPolicy permits egress to the guard and to OpenSearch and
    to nothing else. Pointing this function at the model directly would not
    weaken the guardrail quietly, it would fail to connect.
    """
    prompt = f"{system}\n\n{context}\n\nQuestion: {question}"

    response = requests.post(
        f"{config.GUARD_ENDPOINT}/generate",
        json={"prompt": prompt},
        timeout=_timeout,
    )
    response.raise_for_status()
    payload = response.json()

    return {
        "text": payload.get("text") or "The guardrail blocked this response.",
        "guardrail_intervened": bool(payload.get("guardrail_intervened")),
        "stop_reason": payload.get("stop_reason"),
    }


def vector_client(endpoint: str | None = None) -> OpenSearch:
    """A read-only client for the in-cluster vector store.

    The credentials here belong to a user with `read` on the index and nothing
    else. Ingestion uses a different user. That is the same separation the AOSS
    data access policy expresses, enforced by OpenSearch's own security plugin
    rather than by IAM -- and it is what makes corpus poisoning by prompt
    injection impossible rather than merely unlikely.
    """
    host = (endpoint or config.VECTOR_ENDPOINT).replace("https://", "").replace("http://", "")
    port = 9200
    if ":" in host:
        host, _, raw_port = host.partition(":")
        port = int(raw_port)

    return OpenSearch(
        hosts=[{"host": host, "port": port}],
        http_auth=(config.VECTOR_USERNAME, config.VECTOR_PASSWORD),
        use_ssl=config.VECTOR_USE_TLS,
        verify_certs=config.VECTOR_VERIFY_CERTS,
        ssl_show_warn=False,
        pool_maxsize=20,
    )


def log_event(event: dict) -> None:
    """One JSON object per line on stdout.

    The cluster's log collector is the SIEM's source here, the way CloudWatch
    Logs is in the deployed platform. Weaker in one specific way: this is the
    application reporting on itself.
    """
    try:
        sys.stdout.write(json.dumps(event, separators=(",", ":")) + "\n")
        sys.stdout.flush()
    except Exception:
        # Telemetry must never be the reason a request fails.
        return
