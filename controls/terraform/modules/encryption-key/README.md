# encryption-key

A customer-managed KMS key with rotation enabled and a key policy that grants
only what the caller names.

Used twice in this platform, deliberately: once by the platform layer for
cluster secrets and flow logs, once by the AI layer for prompts, documents and
vectors. Two keys means compromise of one does not expose the other, and key
usage in CloudTrail tells you which domain was touched.

Workload access is granted through IAM policies on the consuming role rather
than listed here. That keeps the key independent of the roles that use it —
otherwise the key would depend on the role, the role's policy would depend on
the buckets, and the buckets would depend on the key.
