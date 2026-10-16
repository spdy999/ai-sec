# bastion

The only way a human reaches this VPC.

An EC2 instance in a private subnet with a security group that has **no ingress
rules at all**. Access is AWS Systems Manager Session Manager: the agent dials
out to the SSM interface endpoints, and the operator's session is brokered back
down that connection. There is no SSH, no key pair, no public IP and no port to
scan.

That is worth more than the convenience. A jump host reached over SSH from an
office CIDR is a jump host whose exposure is a firewall rule away from being
wrong. This one cannot be reached inbound at all, and every session is an IAM
call recorded in CloudTrail against a named principal.

The instance's posture lives in a launch template rather than on the instance.
That is deliberate: the policy rules that check IMDSv2, the metadata hop limit
and root volume encryption read `aws_launch_template`. Configuring the instance
directly would be equally secure and entirely unproven, which in this repository
is the same as insecure.

It holds no Kubernetes permissions of its own. Access to the cluster comes from
an EKS access entry naming this instance role, so revoking it is a decision
taken on the Kubernetes side with its own audit trail, not a matter of editing
the instance.
