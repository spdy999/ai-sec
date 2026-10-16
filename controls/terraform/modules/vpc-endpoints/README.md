# vpc-endpoints

The only way out of the VPC.

Creates one security group that accepts HTTPS from a named workload security
group and nothing else, then attaches interface endpoints for the AWS services
the workload legitimately needs, plus an optional S3 gateway endpoint.

Instantiated twice. The eks-platform layer opens the endpoints a node needs in order
to boot at all — ECR, STS, CloudWatch Logs, EKS — and the S3 gateway that ECR
image layers are fetched through. The bedrock-ai layer opens `bedrock-runtime` and
attaches an endpoint policy to it.

The endpoint policy matters more than it looks. IAM says what a role may do;
the endpoint policy says what may be done *through this network path*. A
compromised pod that somehow acquires a broader IAM policy still cannot reach an
unapproved model from inside this VPC.
