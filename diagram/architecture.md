# Architecture

Secure enterprise GenAI assistant on AWS Bedrock and EKS.

All three diagrams below are backed by the Terraform module in
`controls/terraform/`, so the picture and the code cannot drift apart. Resource
names in the notes refer to real addresses in that module.

---

## 1. Platform overview

The main diagram. Four trust boundaries, one direction of travel: a request
crosses each boundary only through a single mediated chokepoint.

```mermaid
flowchart TB
    subgraph corporate["🏢 Corporate zone — trusted users, untrusted input"]
        user["Employee<br/><i>browser / Teams</i>"]
        idp["Entra ID<br/><i>SSO, MFA, group claims</i>"]
    end

    subgraph edge["🌐 Edge — authentication and rate control"]
        waf["WAF + API Gateway<br/><i>TLS, throttling, OIDC validation</i>"]
    end

    subgraph platform["☸️ Platform zone — EKS, private subnets, no internet egress"]
        direction TB
        proxy["<b>AI mediation layer</b><br/><i>guardrail proxy — CONTROL 2</i><br/>input scan · RAG ACL · tool allow-list · output redaction"]
        tools["Tool / MCP executor<br/><i>approved business APIs only</i>"]
    end

    subgraph data["🔒 Data zone — CMK encrypted, VPC endpoint only"]
        direction TB
        vectors[("OpenSearch Serverless<br/><i>vector store</i><br/>AllowFromPublic = false")]
        docs[("S3 RAG corpus<br/><i>versioned, TLS enforced</i>")]
        bedrock["Amazon Bedrock<br/><i>approved models + guardrail</i>"]
    end

    subgraph observe["📊 Security operations"]
        logs["CloudWatch<br/><i>invocation audit trail</i>"]
        siem["SIEM<br/><i>detections, alerting</i>"]
    end

    user -->|"1 authenticate"| idp
    idp -->|"2 OIDC token + groups"| waf
    waf -->|"3 mTLS"| proxy

    proxy -->|"4 retrieve, filtered by user groups"| vectors
    vectors -.->|"source documents"| docs
    proxy -->|"5 InvokeModel + guardrailIdentifier<br/><i>PrivateLink, never public internet</i>"| bedrock
    proxy -->|"6 invoke, only if on allow-list"| tools

    proxy -->|"security events"| logs
    bedrock -->|"model invocation logs"| logs
    logs --> siem

    classDef boundary fill:#f8f9fb,stroke:#5b6b8c,stroke-width:2px
    classDef control fill:#fff4e6,stroke:#d97706,stroke-width:3px,color:#7c2d12
    classDef store fill:#eef6ff,stroke:#2563eb
    classDef sec fill:#f0fdf4,stroke:#16a34a

    class proxy control
    class vectors,docs,bedrock store
    class logs,siem sec
```

**Why the shape is this shape**

| Decision | Reason |
|---|---|
| One mediation layer, no direct model access | A single chokepoint is the only place a guardrail can be enforced consistently. Anything that bypasses it still meets the server-side Bedrock guardrail — defence in depth, not a single wall. |
| Data zone has no route to the internet | Inference and retrieval traffic uses VPC endpoints (`aws_vpc_endpoint.bedrock_runtime`, `aws_vpc_endpoint.s3`). There is no NAT gateway, so an exfiltration attempt has no network path. |
| Retrieval is filtered *before* the model sees it | The model cannot keep a secret it was never given. Document-level ACL enforcement at step 4 is stronger than asking the model to withhold an answer at step 5. |
| Tool execution is separated from the proxy | The component that decides *whether* a tool may run is not the component that runs it. |

---

## 2. Zoom-in — the request path through the guardrail

Where Control 2 sits, and what happens to a malicious request. Every numbered
decision is a deny point.

```mermaid
sequenceDiagram
    autonumber
    participant U as Employee
    participant P as Mediation layer
    participant V as Vector store
    participant B as Bedrock
    participant T as Tool executor
    participant S as SIEM

    U->>P: question + OIDC token

    rect rgba(255, 244, 230, 0.6)
        note over P: INPUT INSPECTION
        P->>P: validate token, extract group claims
        P->>P: scan for prompt injection patterns
        P->>P: detect and mask PII before it leaves the estate
    end

    alt injection detected
        P-->>U: refused, generic message
        P->>S: 🚨 ai.prompt_injection.blocked
    else clean
        P->>V: similarity search, filtered by user groups
        V-->>P: only chunks this user may read

        rect rgba(238, 246, 255, 0.6)
            note over P,B: context is assembled with retrieved text<br/>clearly delimited as DATA, not instructions
            P->>B: InvokeModel + guardrailIdentifier (pinned version)
            B-->>P: response
        end

        opt model requests a tool
            P->>P: is this tool on the allow-list for this user?
            alt not allowed
                P-->>U: refused
                P->>S: 🚨 ai.tool.denied
            else allowed
                P->>T: execute with scoped, short-lived credentials
                T-->>P: result
            end
        end

        rect rgba(255, 244, 230, 0.6)
            note over P: OUTPUT INSPECTION
            P->>P: redact PII and secrets from the answer
            P->>P: verify no citation outside the user's permitted set
        end

        P-->>U: answer + citations
        P->>S: ai.request.completed (decision trail)
    end
```

**The key insight in this diagram**

Retrieved document text is inserted into the prompt as *data*, never as
instructions. This is the structural answer to prompt injection: the attack
works by making the model mistake content for commands, so the mitigation is to
mark the boundary explicitly and to filter at retrieval time — not to ask the
model politely to ignore it.

---

## 3. Zoom-in — identity and permissions

No static credentials exist anywhere in this design. Each arrow is a trust
relationship that can be revoked independently.

```mermaid
flowchart LR
    subgraph human["Human identity"]
        emp["Employee"]
        grp["Entra ID group<br/><i>drives document ACLs</i>"]
    end

    subgraph nhi["Non-human identity (NHI)"]
        sa["K8s ServiceAccount<br/><code>genai-platform/genai-mediation</code>"]
        oidc["EKS OIDC provider"]
        role["IAM role<br/><code>*-mediation</code>"]
    end

    subgraph perms["What that role may do — and nothing else"]
        p1["bedrock:InvokeModel<br/><i>only approved model ARNs</i><br/><i>only with the guardrail attached</i>"]
        p2["s3:GetObject<br/><i>RAG bucket only</i>"]
        p3["aoss:APIAccessAll<br/><i>one collection</i>"]
        p4["logs:PutLogEvents<br/><i>one log group</i>"]
    end

    emp --> grp
    grp -.->|"filters retrieval"| p2

    sa -->|"projected token"| oidc
    oidc -->|"AssumeRoleWithWebIdentity<br/><b>sub pinned to one service account</b>"| role
    role --> p1
    role --> p2
    role --> p3
    role --> p4

    classDef deny fill:#fef2f2,stroke:#dc2626,stroke-dasharray: 5 3,color:#7f1d1d
    classDef ok fill:#f0fdf4,stroke:#16a34a

    class p1,p2,p3,p4 ok
```

**Two details that matter under questioning**

1. **The trust policy pins one service account.** `StringEquals` on the `sub`
   claim, matching exactly
   `system:serviceaccount:genai-platform:genai-mediation`. A `StringLike` with a
   wildcard here would let *any* pod in the cluster assume the role and read the
   entire document corpus. The policy gate in `controls/policy/iam.rego` rejects
   that pattern, and the insecure fixture proves it fires.

2. **The model allow-list is enforced twice.** Once in the IAM policy, and again
   in the VPC endpoint policy. A pod that somehow obtained broader IAM
   permissions still cannot reach an unapproved model from inside this VPC.

---

## Assumptions

- Entra ID is the enterprise IdP and already issues group claims usable for
  document-level authorisation.
- The EKS cluster, VPC, subnets and node security group exist and are managed
  outside this module; they are passed in as variables.
- Synthetic values are used for all account IDs, VPC IDs and subnet IDs.
- `eu-central-1` is the designated region for EU data residency.

## Limitations

- Nothing here is deployed. The design is validated offline against the rendered
  Terraform plan; it has not been applied to a live AWS account.
- IRSA token exchange cannot be tested without a real OIDC provider and STS. The
  trust policy *document* is validated by policy-as-code; the runtime exchange is
  not.
- Azure AI Foundry is not drawn. The same structure maps onto it — Entra ID
  workload identity in place of IRSA, Private Link in place of VPC endpoints,
  Azure Policy in place of the OPA gate.
