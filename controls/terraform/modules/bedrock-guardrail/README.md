# bedrock-guardrail

The server-side control on the model itself.

It matters that this is configuration rather than code. The guardrail is
enforced by Bedrock on every `InvokeModel` call that carries its identifier, so
it still applies if the mediation service is bypassed, misconfigured, or
compromised. A filter reimplemented in the application would be a second
detection engine that can silently disagree with this one.

What it enforces:

| Setting | Stops |
|---|---|
| `PROMPT_ATTACK`, input strength HIGH | Instructions smuggled in through a question or a retrieved document |
| PII entities: EMAIL, PHONE anonymised | Personal data leaving in a generated answer |
| CREDIT_DEBIT_CARD_NUMBER blocked | Card numbers, which are never a legitimate answer |
| Regex `EMP-[0-9]{6}` | Internal employee identifiers |
| Denied topic: credential disclosure | "What is the HR database password?" |

The version resource pins a snapshot. The mediation layer references that
version, never `DRAFT`, so an edit in the console cannot change production
behaviour without a deployment.
