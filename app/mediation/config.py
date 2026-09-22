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

    OLLAMA_ENDPOINT = ""
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

    # The model endpoint is here only for embeddings. Generation goes through
    # GUARD_ENDPOINT, and NetworkPolicy is what stops this pod taking the
    # shortcut -- see providers/local.py.
    OLLAMA_ENDPOINT = _required("OLLAMA_ENDPOINT").rstrip("/")
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
#
# On AWS it comes from Secrets Manager, read with the pod's own IRSA
# credentials, so no Kubernetes Secret holds it and no manifest can print it.
# The local provider has no Secrets Manager to read, so it keeps the
# environment variable -- which is also what the token minting CLI uses.
IDENTITY_SECRET_ARN = os.environ.get("IDENTITY_SECRET_ARN", "")

if IDENTITY_SECRET_ARN:
    from mediation import secrets as _secrets

    JWT_SECRET = _secrets.secret_string(IDENTITY_SECRET_ARN, AWS_REGION)
else:
    JWT_SECRET = _required("IDENTITY_TOKEN_SECRET")
JWT_ISSUER = os.environ.get("IDENTITY_TOKEN_ISSUER", "genai-assistant-demo")

TOP_K = int(os.environ.get("RETRIEVAL_TOP_K", "4"))

# Bedrock evaluates its prompt-attack filter only on text the caller marks as
# user input. Untagged, a guardrail carrying PROMPT_ATTACK at HIGH reads the
# whole prompt as trusted and never fires: the model's own refusal is then all
# that stands between an injection and an answer, and the response says
# `guardrail_intervened: false` while looking perfectly safe. The suffix is
# arbitrary; it only has to match on both halves of the call.
GUARD_TAG = "question"
