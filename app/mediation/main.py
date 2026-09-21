"""The mediation service.

Three things happen between a question and an answer, in this order:

1. The caller is identified from a signed token.
2. Retrieval is filtered by that caller's entitlements, in the query.
3. The model is invoked with the guardrail attached, which IAM requires.

Every one of those is enforced somewhere other than this file as well -- the
trust policy, the data access policy, the IAM condition on
`bedrock:GuardrailIdentifier`. This code is the convenient path, not the
boundary.
"""

import pathlib

from fastapi import FastAPI, Header, HTTPException
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from . import answering, config, identity, retrieval, telemetry

app = FastAPI(title="genai-assistant mediation layer", docs_url=None, redoc_url=None)

# The built React bundle, copied in by the image build. Mounted rather than
# proxied: this service is the only thing the browser talks to, so there is no
# second origin and no CORS to get wrong.
_STATIC = pathlib.Path(__file__).parent / "static"


class Question(BaseModel):
    question: str = Field(min_length=1, max_length=2000)


@app.get("/healthz")
def healthz() -> dict:
    """Liveness: the process is up. Deliberately touches nothing else -- a
    liveness probe that calls AWS restarts the pod during an AWS outage."""
    return {"status": "ok"}


@app.get("/readyz")
def readyz() -> dict:
    """Readiness: configuration resolved at import, so reaching this handler is
    itself the check. A half-configured process raised at import and never
    started."""
    return {
        "status": "ready",
        "guardrail": config.GUARDRAIL_ID,
        "guardrail_version": config.GUARDRAIL_VERSION,
        "index": config.VECTOR_INDEX,
    }


@app.get("/")
def index() -> FileResponse:
    return FileResponse(_STATIC / "index.html")


@app.post("/ask")
def ask(body: Question, authorization: str | None = Header(default=None)) -> dict:
    try:
        caller = identity.caller_from_authorization(authorization)
    except identity.IdentityError as exc:
        # No retrieval has happened at this point, which is the intended order.
        raise HTTPException(status_code=401, detail=str(exc)) from exc

    passages = retrieval.search(body.question, caller.groups)
    result = answering.answer(body.question, passages)

    telemetry.record(
        {
            "event": "question_answered",
            "subject": caller.subject,
            "groups": sorted(caller.groups),
            "documents": sorted({p["document"] for p in passages}),
            "passages": len(passages),
            "guardrail_intervened": result["guardrail_intervened"],
        }
    )

    return {
        "answer": result["text"],
        "guardrail_intervened": result["guardrail_intervened"],
        "sources": sorted({p["document"] for p in passages}),
        "caller": {"subject": caller.subject, "groups": sorted(caller.groups)},
    }


# Mounted last so /healthz and /ask keep their handlers. Vite emits hashed
# filenames under assets/, which is why this can be served with a long cache
# lifetime and still never serve a stale bundle.
app.mount("/assets", StaticFiles(directory=_STATIC / "assets"), name="assets")
