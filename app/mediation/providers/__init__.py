"""Where the models and the vector store come from.

Two implementations behind one interface:

  bedrock  the platform as designed -- Bedrock for inference, Bedrock
           Guardrails for enforcement, OpenSearch Serverless for vectors, IRSA
           for credentials.

  local    the same architecture with no cloud account -- Ollama for inference,
           Llama Guard as a separate guard service for enforcement, OpenSearch
           in-cluster for vectors, Kubernetes service accounts for identity.

The interface is deliberately narrow, and the split is deliberately here rather
than inside retrieval.py or answering.py. Those two modules hold the controls
this platform exists to demonstrate -- the entitlement filter inside the query,
the guardrail on every invocation -- and neither should have to know which
backend it is talking to. A control that is written twice is a control that can
drift.

Each provider exposes:

    embed(text)                  -> list[float]
    generate(prompt)             -> {"text", "guardrail_intervened", "stop_reason"}
    vector_client(endpoint=None) -> opensearchpy.OpenSearch
    log_event(event)             -> None

`generate` is guarded in both. In Bedrock the guardrail is a parameter on the
invocation and IAM refuses the call without it. Locally the guard is a separate
service and NetworkPolicy refuses the pod any route to the model except through
it. Different mechanisms, same property: the application cannot choose to skip
the guardrail.
"""

from .. import config

if config.PROVIDER == "bedrock":
    from . import bedrock as _impl
elif config.PROVIDER == "local":
    from . import local as _impl
else:  # pragma: no cover - refused at import, before anything can serve
    raise RuntimeError(
        f"MODEL_PROVIDER={config.PROVIDER!r} is not a provider; expected 'bedrock' or 'local'"
    )

embed = _impl.embed
generate = _impl.generate
vector_client = _impl.vector_client
log_event = _impl.log_event

__all__ = ["embed", "generate", "vector_client", "log_event"]
