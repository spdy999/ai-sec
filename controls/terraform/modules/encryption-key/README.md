# encryption-key

A customer-managed KMS key with rotation enabled and a key policy that grants
only what the caller names.

Used twice, deliberately: once by the eks-platform layer for Kubernetes Secrets
and flow logs, once by the bedrock-ai layer for prompts, documents and vectors. Two keys means compromise of one does not expose the other, and key
usage in CloudTrail tells you which domain was touched.

Workload access is granted through IAM policies on the consuming role rather
than listed here. That keeps the key independent of the roles that use it —
otherwise the key would depend on the role, the role's policy would depend on
the buckets, and the buckets would depend on the key.
