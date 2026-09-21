"""Configuration, read once at import.

Everything here arrives as an environment variable from the ConfigMap that
Terraform's outputs populate. Nothing is discovered at runtime: a service that
looks up its own guardrail ID can be pointed at a different one.
"""

import os


def _required(name: str) -> str:
    value = os.environ.get(name, "")
    if not value:
        raise RuntimeError(f"{name} is not set; refusing to start half-configured")
    return value


AWS_REGION = os.environ.get("AWS_REGION", "eu-central-1")

# The guardrail is not optional and not defaulted. Starting without one would
# mean answering questions with no server-side filtering at all, which is the
# failure this service exists to prevent.
GUARDRAIL_ID = _required("BEDROCK_GUARDRAIL_ID")
GUARDRAIL_VERSION = _required("BEDROCK_GUARDRAIL_VERSION")

CHAT_MODEL_ID = _required("BEDROCK_CHAT_MODEL_ID")
EMBEDDING_MODEL_ID = _required("BEDROCK_EMBEDDING_MODEL_ID")

VECTOR_ENDPOINT = _required("VECTOR_COLLECTION_ENDPOINT")
VECTOR_INDEX = os.environ.get("VECTOR_INDEX", "genai-corpus")

TELEMETRY_LOG_GROUP = os.environ.get("TELEMETRY_LOG_GROUP", "")

# Shared secret for the demo identity tokens. In production this is an OIDC
# provider's public key and the verification below becomes RS256 against a JWKS
# endpoint; the claim handling does not change.
JWT_SECRET = _required("IDENTITY_TOKEN_SECRET")
JWT_ISSUER = os.environ.get("IDENTITY_TOKEN_ISSUER", "genai-assistant-demo")

TOP_K = int(os.environ.get("RETRIEVAL_TOP_K", "4"))
