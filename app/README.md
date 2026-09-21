# Mediation layer

The only thing in this architecture that holds custom code. Everything else is
configuration: the guardrail, the model allow-list, the entitlement boundary and
the network path are all enforced outside this process.

That is the design claim, and it is worth stating what it costs. This service
could be deleted and replaced tomorrow and the platform's security properties
would not change, because none of them depend on it behaving. What it provides
is the *convenient* path: identity-aware retrieval, in one place, so that every
team does not reimplement it.

## What happens between a question and an answer

1. **Identify.** `identity.py` verifies a signed bearer token — signature,
   expiry and issuer. No retrieval has happened yet, which is the point of the
   ordering.
2. **Retrieve, filtered.** `retrieval.py` puts the caller's groups into the
   kNN query as a `terms` filter on `allowed_groups`. A passage the caller
   cannot see is never a candidate. Filtering results afterwards would mean the
   process had already read the restricted text.
3. **Answer, guarded.** `answering.py` invokes the approved model with
   `guardrailIdentifier` attached. The IRSA policy conditions
   `bedrock:InvokeModel` on that value, so an unguarded call is refused by IAM
   before it reaches Bedrock. Dropping the argument does not weaken the service
   quietly — it stops it working.
4. **Record.** `telemetry.py` writes one JSON line: who asked, which documents
   came back, whether the guardrail intervened. Never the question and never the
   answer. A prompt log is a copy of every sensitive thing anyone typed, kept
   somewhere with weaker controls than the source it came from.

## What is deliberately not here

**The ingester does not run in the service.** `ingest.py` is an operator tool.
The OpenSearch data access policy grants writes to the jump host role only, so
the running service physically cannot write to the index. A prompt injection
that reaches the retrieval path cannot poison the corpus, because the identity
executing it has no permission to.

**Tokens are not minted here.** `tokens.py` is a separate command. A service
that issues its own identity tokens has no authentication, only ceremony.

## Layout

```
mediation/        the service
  config.py       environment, resolved once at import; missing values refuse to start
  identity.py     token verification and the group set
  retrieval.py    entitlement-filtered kNN search
  answering.py    the guarded model call
  telemetry.py    security events, no prompt text
  ingest.py       operator tool: corpus to embeddings to index
  tokens.py       operator tool: mint a demo identity
web/              React front-end, bundled into the image at build time
Dockerfile        three stages; the shipped image has no compiler and no npm
```

## Running it locally

There is no local mode worth having: every dependency is an AWS service behind a
private endpoint. Build the image and deploy it — `docs/RUNBOOK.md` has the
sequence.

The front-end alone can be developed against a running service:

```bash
cd web && npm install && npm run dev   # proxies /ask to 127.0.0.1:8080
```
