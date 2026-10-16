# eks-cluster

The control plane, its nodes and its addons, built on
[`terraform-aws-modules/eks`](https://registry.terraform.io/modules/terraform-aws-modules/eks/aws).

This replaced a hand-written module of about 280 lines. That module satisfied
every rule in this repository's policy gate, and was still wrong in three ways
that only a real `terraform apply` exposed:

- **No node egress to the S3 prefix list.** The S3 gateway endpoint is a route,
  not an ENI, so traffic to it leaves the node addressed to S3 and needs a
  prefix list rule. ECR serves image layers out of S3, so the VPC CNI image
  never arrived, the node registered and stayed NotReady, and the node group sat
  in `CREATING` for twenty minutes reporting no health issue at all.
- **No KMS grant for Auto Scaling.** Node root volumes use the platform CMK, and
  Auto Scaling attaches them as its own service-linked role rather than as the
  caller. Every node was terminated within a minute with
  `Client.InvalidKMSKey.InvalidState: The KMS key provided is in an incorrect
  state` — a message that names the key and not the missing permission.
- **No declared addons.** Whatever EKS happened to pre-install was what ran, at
  whatever version, unmanaged.

Upstream gets all three right by default. That is the argument for using it:
not that the hand-written version was badly written, but that a widely used
module has already been run against reality by thousands of people, and this one
had been run zero times.

## What is configured here

Only the security posture. Everything unnamed is upstream's default, and
upstream's defaults for this module are already private-endpoint, IMDSv2 and
encrypted.

The exception worth knowing about is `node_security_group_enable_recommended_rules`,
which upstream defaults to `true` and which adds node egress to `0.0.0.0/0`.
That is the exfiltration path this whole architecture exists to remove, so it is
turned off and every rule is written out: HTTPS to the interface endpoints,
HTTPS to S3 through the gateway endpoint, and the kubelet port for operator
port-forwarding.

## The cost of the change

`eks-platform` can no longer be planned without AWS credentials. Upstream reads
`aws_caller_identity`, `aws_partition` and `aws_iam_session_context` during
plan. That layer is gated in the deploy pipeline instead, against the saved plan
immediately before it is applied — better evidence, since the bytes checked are
the bytes that run, but it is no longer free and no longer runs on a laptop.

The AI layer, the insecure fixtures, the workload manifests and the coverage
gate are unaffected and still run offline at zero cost.
