"""Configuration, read once at import.

Everything here arrives as an environment variable from the ConfigMap that
Terraform's outputs populate. Nothing is discovered at runtime: a service that
looks up its own guardrail ID can be pointed at a different one.

MODEL_PROVIDER selects which backend the process talks to. It is read first,
because which variables are mandatory depends on it: demanding a Bedrock
guardrail ID from a process that will never call Bedrock would be a startup
failure with no security meaning, and demanding nothing would let a Bedrock
deployment start with no guardrail at all. Both halves stay strict.
"""

import os


def _required(name: str) -> str:
    value = os.environ.get(name, "")
    if not value:
        raise RuntimeError(f"{name} is not set; refusing to start half-configured")
    return value


def _flag(name: str, default: str = "false") -> bool:
    return os.environ.get(name, default).strip().lower() in {"1", "true", "yes"}


PROVIDER = os.environ.get("MODEL_PROVIDER", "bedrock").strip().lower()

AWS_REGION = os.environ.get("AWS_REGION", "eu-central-1")

if PROVIDER == "bedrock":
    # The guardrail is not optional and not defaulted. Starting without one
    # would mean answering questions with no server-side filtering at all,
    # which is the failure this service exists to prevent.
    GUARDRAIL_ID = _required("BEDROCK_GUARDRAIL_ID")
    GUARDRAIL_VERSION = _required("BEDROCK_GUARDRAIL_VERSION")

    CHAT_MODEL_ID = _required("BEDROCK_CHAT_MODEL_ID")
    EMBEDDING_MODEL_ID = _required("BEDROCK_EMBEDDING_MODEL_ID")

    GUARD_ENDPOINT = ""
    LOCAL_TIMEOUT_SECONDS = 0
    VECTOR_USERNAME = ""
    VECTOR_PASSWORD = ""
    VECTOR_USE_TLS = True
    VECTOR_VERIFY_CERTS = True
else:
    GUARDRAIL_ID = ""
    GUARDRAIL_VERSION = ""

    CHAT_MODEL_ID = os.environ.get("CHAT_MODEL_ID", "qwen2.5:3b")
    EMBEDDING_MODEL_ID = os.environ.get("EMBEDDING_MODEL_ID", "nomic-embed-text")

    # One inference endpoint, and it is the guard. There is deliberately no
    # model address here: a pod that knows how to reach the model, and is
    # permitted to, can call the chat endpoint whatever its own code says.
    # Embeddings go through the guard for exactly that reason.
    GUARD_ENDPOINT = _required("GUARD_ENDPOINT").rstrip("/")
    LOCAL_TIMEOUT_SECONDS = int(os.environ.get("LOCAL_TIMEOUT_SECONDS", "120"))

    # Read-only credentials. Ingestion authenticates as a different user; see
    # the write separation note in providers/local.py.
    VECTOR_USERNAME = _required("VECTOR_USERNAME")
    VECTOR_PASSWORD = _required("VECTOR_PASSWORD")
    VECTOR_USE_TLS = _flag("VECTOR_USE_TLS", "false")
    VECTOR_VERIFY_CERTS = _flag("VECTOR_VERIFY_CERTS", "false")

VECTOR_ENDPOINT = _required("VECTOR_COLLECTION_ENDPOINT")
VECTOR_INDEX = os.environ.get("VECTOR_INDEX", "genai-corpus")

TELEMETRY_LOG_GROUP = os.environ.get("TELEMETRY_LOG_GROUP", "")

# Shared secret for the demo identity tokens. In production this is an OIDC
# provider's public key and the verification below becomes RS256 against a JWKS
# endpoint; the claim handling does not change.
JWT_SECRET = _required("IDENTITY_TOKEN_SECRET")
JWT_ISSUER = os.environ.get("IDENTITY_TOKEN_ISSUER", "genai-assistant-demo")

TOP_K = int(os.environ.get("RETRIEVAL_TOP_K", "4"))
