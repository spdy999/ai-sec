# workload-identity

The IAM role the mediation pod assumes, and the only place in this platform
where an identity is granted access to data.

**No static credentials exist anywhere.** The pod presents a projected service
account token to STS and receives short-lived credentials. There is no access
key on the node, in a Secret, or in an environment variable to steal.

Two conditions carry the control:

```hcl
"${oidc}:sub" = "system:serviceaccount:genai-platform:genai-mediation"
"${oidc}:aud" = "sts.amazonaws.com"
```

`StringEquals`, not `StringLike`. A wildcard in the `sub` condition — the single
most common IRSA mistake — would let **any** pod in the cluster assume this role,
which collapses every namespace boundary in the cluster into one.

The permission policy is scoped the same way. `bedrock:InvokeModel` is allowed
only on the approved model ARNs, and only when the request carries the pinned
guardrail:

```hcl
condition {
  test     = "StringEquals"
  variable = "bedrock:GuardrailIdentifier"
  values   = [guardrail_id]
}
```

An unguarded call to an approved model is denied by IAM. That is what makes the
guardrail non-optional rather than merely default.
