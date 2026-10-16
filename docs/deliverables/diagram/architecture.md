# Architecture

Secure enterprise GenAI assistant on AWS Bedrock and EKS.

Every component below is deployed in account `891377211626`, `eu-central-1`, and
backed by Terraform in `controls/terraform/`. Anything designed but not built is
listed at the end rather than drawn, so the picture cannot claim more than the
account contains.

---

## 1. Platform overview

Four trust boundaries. A request crosses each one through a single mediated
chokepoint, and no boundary is crossed by the model's own judgement.

```mermaid
flowchart LR
    subgraph corporate["🏢 Caller zone — trusted user, untrusted input"]
        user["Employee<br/><i>browser, signed token<br/>carrying subject + groups</i>"]
    end

    subgraph platform["☸️ Platform zone — EKS, private subnets, no internet egress"]
        api["EKS API server<br/><i>private endpoint, no public access</i>"]
        proxy["<b>Mediation service</b><br/><i>FastAPI on EKS, IRSA</i><br/>validates the token · filters retrieval<br/>by group · records telemetry"]
    end

    subgraph operator["🛠️ Operator zone — Session Manager only, no ingress"]
        bastion["Jump host<br/><i>the only writer</i><br/>indexes the corpus · generates secrets<br/>applies manifests"]
    end

    subgraph data["🔒 Data zone — CMK encrypted, reached only by VPC endpoint"]
        bedrock["Amazon Bedrock<br/><i>Converse + guardrail version</i><br/>EU inference profile"]
        vectors[("OpenSearch Serverless<br/><i>vector index</i><br/>service reads · jump host writes")]
        docs[("S3 RAG corpus<br/><i>versioned, CMK</i>")]
        secrets[("Secrets Manager<br/><i>signing key + TLS pair</i><br/>resource policy names two roles")]
    end

    subgraph observe["📊 Security operations"]
        telemetry["CloudWatch Logs<br/><i>mediation telemetry, no prompt text</i>"]
        trail["CloudTrail<br/><i>Converse + ApplyGuardrail events</i>"]
        alarms["3 metric filters + alarms<br/><i>interventions · refusals · AccessDenied</i>"]
        sns["SNS topic, CMK encrypted"]
        queue[("SQS queue<br/><i>proves delivery</i>")]
    end

    user -->|"1 question + token"| proxy
    proxy -->|"2 search, filtered by allowed_groups"| vectors
    proxy -->|"3 Converse + guardrailIdentifier"| bedrock
    proxy -->|"startup"| secrets
    proxy -->|"refusals, interventions"| telemetry

    bastion -->|"kubectl apply over SSM"| api
    api --> proxy

    bastion --> vectors
    bastion --> docs
    bastion --> secrets

    bedrock --> trail
    telemetry --> alarms
    trail --> alarms
    alarms --> sns --> queue

    classDef control fill:#fff4e6,stroke:#d97706,stroke-width:3px,color:#7c2d12
    classDef store fill:#eef6ff,stroke:#2563eb
    classDef sec fill:#f0fdf4,stroke:#16a34a
    classDef ops fill:#f5f3ff,stroke:#7c3aed

    class proxy control
    class vectors,docs,bedrock,secrets store
    class telemetry,trail,alarms,sns,queue sec
    class bastion ops
    class api control
```

**Why the shape is this shape**

| Decision | Reason |
|---|---|
| One mediation service, no direct model access | A single chokepoint is the only place entitlement can be enforced consistently. Anything reaching Bedrock another way still meets the server-side guardrail — defence in depth, not a single wall. |
| Retrieval is filtered *before* the model sees it | The model cannot leak a passage it was never given. The filter is a `terms` clause on `allowed_groups` inside the search query, not a post-hoc check on the answer. |
| The service reads the index and never writes it | The OpenSearch data access policy grants writes to the jump host role alone, so corpus poisoning by prompt injection is impossible rather than unlikely — the identity running the injection has no write permission to use. |
| No NAT gateway, no internet gateway, no SSH | Every AWS call leaves through a VPC endpoint; the only way in is Session Manager, which dials out. An exfiltration attempt has no network path. |
| The audit trail carries no prompt text | CloudTrail records the call and the guardrail evaluation, not the content. Replay of what was asked is lost deliberately; a log full of prompts is a second copy of the data the guardrail exists to protect. |

---

## 2. The request path

Every numbered step is a place the request can be refused. The guardrail is
evaluated twice by Bedrock — once on the question, once on the answer.

```mermaid
sequenceDiagram
    autonumber
    participant U as Employee
    participant P as Mediation service
    participant V as OpenSearch
    participant B as Bedrock (Converse + guardrail)
    participant L as CloudWatch

    U->>P: question + signed token

    rect rgba(255, 244, 230, 0.6)
        note over P: ADMISSION
        P->>P: verify signature, extract subject and groups
        P->>P: bound the question — typed, length limited
    end

    alt token missing or invalid
        P-->>U: 401
        P->>L: authorization_refused
    else valid
        P->>V: similarity search, filter allowed_groups = caller groups
        V-->>P: only passages this caller may read

        rect rgba(238, 246, 255, 0.6)
            note over P,B: the question is wrapped in guardContent —<br/>retrieved passages are not, so a planted<br/>injection in a document cannot block the corpus
            P->>B: Converse(system, passages, question) + guardrailIdentifier + version
            B->>B: input: denied topics, prompt attack
            B->>B: output: PII anonymise, card numbers blocked
            B-->>P: answer, or intervention
        end

        alt guardrail intervened on input
            P-->>U: "blocked by the AI security guardrail"
            P->>L: guardrail_intervened
        else answered
            P-->>U: answer + sources
            P->>L: guardrail_intervened only if the output was masked
        end
    end
```

**Three things to say about this diagram under questioning**

1. **`Converse`, not `InvokeModel`.** With `InvokeModel` and the Anthropic
   Messages body, Bedrock ignores the `guardContent` tags entirely: the trace
   returns with every policy unit at zero and `guardrailAction: NONE`, while the
   model's own refusal makes it look like the control worked. The same text
   through `ApplyGuardrail` comes back `BLOCKED` at HIGH confidence — that
   difference is how a misconfigured guardrail is told apart from an unapplied
   one.

2. **Only the question is wrapped.** The `guardContent` block scopes the scan
   rather than enabling it. One corpus document is a planted injection; scanning
   quoted passages would block the corpus instead of the caller.

3. **An anonymisation is an intervention.** A masked answer and a blocked
   request both set `guardrail_intervened`, so the flag alone does not separate
   them — the answer body does.

---

## 3. Identity and permissions

No static credential exists anywhere in this design. Each arrow is a trust
relationship that can be revoked on its own.

```mermaid
flowchart LR
    subgraph human["Caller identity"]
        emp["Employee"]
        grp["Group claim<br/><i>drives the retrieval filter</i>"]
    end

    subgraph nhi["Workload identity"]
        sa["ServiceAccount<br/><code>genai-platform/genai-mediation</code>"]
        oidc["EKS OIDC provider"]
        role["IAM role<br/><code>*-mediation</code>"]
    end

    subgraph perms["What that role may do — and nothing else"]
        p1["bedrock:InvokeModel<br/><i>approved model ARNs only</i><br/><i>only with the guardrail attached</i>"]
        p2["bedrock:InvokeModel on Titan<br/><i>embeddings, separate statement,<br/>no guardrail condition</i>"]
        p3["aoss:APIAccessAll<br/><i>one collection, read only</i>"]
        p4["secretsmanager:GetSecretValue<br/><i>two secret ARNs</i>"]
        p5["kms:Decrypt<br/><i>ViaService: s3, bedrock, secretsmanager</i>"]
        p6["logs:PutLogEvents<br/><i>one log group</i>"]
    end

    emp --> grp
    grp -.->|"filters retrieval"| p3

    sa -->|"projected token"| oidc
    oidc -->|"AssumeRoleWithWebIdentity<br/><b>sub pinned to one service account</b>"| role
    role --> p1
    role --> p2
    role --> p3
    role --> p4
    role --> p5
    role --> p6

    classDef ok fill:#f0fdf4,stroke:#16a34a
    class p1,p2,p3,p4,p5,p6 ok
```

**Four details that matter under questioning**

1. **The trust policy pins one service account.** `StringEquals` on the `sub`
   claim, matching `system:serviceaccount:genai-platform:genai-mediation`
   exactly. A `StringLike` wildcard would let any pod in the cluster assume the
   role and read the corpus. `controls/policy/iam.rego` rejects that pattern and
   the insecure fixture proves the rule fires.

2. **Embeddings need their own statement.** The model grant is conditioned on
   `bedrock:GuardrailIdentifier`; an embedding call carries no guardrail, so
   that condition could never match and the workload could not embed at all.
   Found only by asking a real question.

3. **The model allow-list is enforced twice.** Once in IAM, once in the Bedrock
   VPC endpoint policy. A pod that somehow acquired broader IAM permissions
   still cannot reach an unapproved model from inside this VPC. The endpoint
   pins which model, with a wildcard region; which regions are permitted stays
   in IAM, where the account evaluates it.

4. **Anthropic models are reachable only through an inference profile**, and the
   EU profile routes to six regions — so IAM authorises the
   `inference-profile/` ARN in this account and the `foundation-model/` ARN in
   each of those six. Authorising only the profile produces an AccessDenied that
   names the model ARN and explains nothing.

---

## Designed, not deployed

Drawn nowhere above, because the account does not contain them:

- **Corporate IdP.** In production the token comes from Entra ID with group
  claims. Here the same key signs tokens minted for `alice` and `dana` inside
  the pod, so the authorisation logic is real and the identity source is not.
- **WAF and API Gateway.** There is no public entry point at all; the front end
  is reached through Session Manager and a port-forward.
- **SIEM.** Both streams are CloudWatch log groups, so the seam is a
  subscription filter to Firehose or a cross-account destination. Neither the
  filter nor a destination is written; nothing subscribes today.
- **Tools.** The assistant calls none. It retrieves and it answers.

## Assumptions

- Group names match on both sides — the token's claim and the document's
  `Audience:` header. There is no registry; a typo in either yields zero
  matches.
- `eu-central-1` is the designated region for EU data residency, and the EU
  inference profile's six regions are all inside the EU.
- All sample data is synthetic.

## Limitations

- **The alarms name the metric, not the identity.** A CloudWatch alarm binds to
  one metric, so interventions are summed across every caller.
- **The guardrail runs on the default content-filter tier** (Classic), by
  default rather than by decision.
- **IRSA, EKS access entries and etcd envelope encryption are proven only by
  running the platform**, which this deployment does — but they cannot be
  demonstrated without an account.
