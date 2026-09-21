"""The guard service: the only route from the mediation layer to a model.

Why this is a separate process and not a function call in the mediation service.

Bedrock Guardrails are enforced by the platform. The application passes a
guardrail identifier and Bedrock applies it; IAM refuses the invocation without
one, so the application cannot answer a question unguarded even if its own code
is rewritten. That property -- the guardrail is not the application's to skip --
is the whole reason it is worth anything.

A library the mediation service imports would not have that property. Code
execution inside the mediation pod would be enough to call the model directly.
So the guard runs as its own deployment, with its own service account, and
NetworkPolicy gives the mediation pod egress to this service and to the vector
store and to nothing else. The route to the model does not exist from there.

    mediation ──allowed──> guard ──allowed──> model
        └──────────denied───────────────────────┘

Two consequences worth stating. Both directions are checked, input and output:
an injected instruction that survives retrieval and reaches the model can still
be caught on the way back. And the guard never sees who is asking -- it receives
a prompt, not an identity. Entitlement is the mediation layer's job and stays
there; mixing the two would give this service a reason to hold user context it
has no need for.
"""

import os
import time

import httpx
from fastapi import FastAPI
from pydantic import BaseModel

from . import policy

OLLAMA = os.environ.get("OLLAMA_ENDPOINT", "http://host.containers.internal:11434").rstrip("/")
GUARD_MODEL = os.environ.get("GUARD_MODEL", "llama-guard3:1b")
CHAT_MODEL = os.environ.get("CHAT_MODEL", "qwen2.5:3b")
EMBED_MODEL = os.environ.get("EMBED_MODEL", "nomic-embed-text")
TIMEOUT = float(os.environ.get("GUARD_TIMEOUT_SECONDS", "180"))

app = FastAPI(title="genai guard", docs_url=None, redoc_url=None)

_client = httpx.Client(timeout=TIMEOUT)


class GenerateRequest(BaseModel):
    prompt: str


class EmbedRequest(BaseModel):
    text: str


def _complete(model: str, prompt: str, temperature: float = 0.0) -> str:
    response = _client.post(
        f"{OLLAMA}/api/generate",
        json={
            "model": model,
            "prompt": prompt,
            "stream": False,
            "options": {"temperature": temperature},
        },
    )
    response.raise_for_status()
    return response.json().get("response", "")


def assess(text: str, role: str) -> dict:
    """Classify one message. `role` is User or Agent, per the Llama Guard template."""
    verdict = _complete(
        GUARD_MODEL,
        policy.TEMPLATE.format(
            role=role,
            categories=policy.CATEGORIES,
            conversation=f"{role}: {text}",
        ),
    ).strip()

    lines = [line.strip() for line in verdict.splitlines() if line.strip()]
    unsafe = bool(lines) and lines[0].lower().startswith("unsafe")

    # The model's own labels, not ours. See the note in policy.py: the 1b model
    # answers in its native taxonomy regardless of the numbering we declare, and
    # relabelling its findings to match our policy would make the audit trail
    # say something the classifier did not.
    categories = lines[1].split(",") if unsafe and len(lines) > 1 else []

    return {
        "unsafe": unsafe,
        "categories": [c.strip() for c in categories if c.strip()],
        "role": role,
    }


@app.post("/generate")
def generate(request: GenerateRequest) -> dict:
    started = time.monotonic()

    # Input first. A prompt that fails here never reaches the answering model at
    # all, so an injection cannot spend the model's context arguing with it.
    incoming = assess(request.prompt, "User")
    if incoming["unsafe"]:
        return {
            "text": policy.REFUSAL,
            "guardrail_intervened": True,
            "stop_reason": "guardrail_input",
            "assessment": incoming,
            "latency_ms": int((time.monotonic() - started) * 1000),
        }

    completion = _complete(CHAT_MODEL, request.prompt)

    # Output second. Retrieval can put a poisoned passage in front of the model
    # that no input check would have seen, because the instruction arrived in a
    # document rather than in the question.
    outgoing = assess(completion, "Agent")
    if outgoing["unsafe"]:
        return {
            "text": policy.REFUSAL,
            "guardrail_intervened": True,
            "stop_reason": "guardrail_output",
            "assessment": outgoing,
            "latency_ms": int((time.monotonic() - started) * 1000),
        }

    return {
        "text": completion,
        "guardrail_intervened": False,
        "stop_reason": "stop",
        "assessment": {"unsafe": False, "categories": [], "role": "Agent"},
        "latency_ms": int((time.monotonic() - started) * 1000),
    }


@app.post("/embed")
def embed(request: EmbedRequest) -> dict:
    """Embeddings, for the same reason generation is here: so that the mediation
    pod needs exactly one egress target for inference.

    Retrieval needs to embed the caller's question, which means the mediation
    service needs *an* inference call. If that call went straight to the model
    host, the NetworkPolicy would have to permit that pod to reach the model --
    and a pod permitted to reach the model on port 11434 can call the chat
    endpoint too, whatever its own source code says. The guardrail would then be
    a convention again.

    No classification here. An embedding of a hostile question is not itself
    dangerous, and refusing to embed it would only move the block earlier and
    tell the caller less. The question is classified when it is answered.
    """
    response = _client.post(
        f"{OLLAMA}/api/embeddings",
        json={"model": EMBED_MODEL, "prompt": request.text},
    )
    response.raise_for_status()
    return {"embedding": response.json()["embedding"]}


@app.get("/healthz")
def healthz() -> dict:
    return {"status": "ok"}


@app.get("/readyz")
def readyz() -> dict:
    """Ready only when the guard model answers.

    Reporting ready before that would let the mediation service start sending
    traffic to a guard that cannot classify anything, and a guard that fails
    open is worse than no guard: it looks like a control on the diagram.
    """
    try:
        _client.get(f"{OLLAMA}/api/version").raise_for_status()
    except Exception as error:  # noqa: BLE001 - surfaced verbatim to the probe
        return {"status": "unavailable", "detail": str(error)[:200]}
    return {"status": "ok"}
