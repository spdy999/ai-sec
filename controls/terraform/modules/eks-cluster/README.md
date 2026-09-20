# eks-cluster

The Kubernetes control plane, its audit trail, and the identity bridge that
lets a pod hold an AWS identity without a static key.

Four decisions worth defending:

- **`endpoint_public_access = false`.** The API server is not on the internet.
  Administrative access arrives over the private network.
- **Secrets are envelope-encrypted with a CMK.** Without `encryption_config`,
  a Kubernetes Secret is base64 in etcd, which is not encryption.
- **All five control plane log types, `audit` included.** The audit log is the
  only record of who changed RBAC or read a Secret, and it is the source every
  Kubernetes detection rule reads from.
- **`authentication_mode = "API"` with bootstrap admin disabled.** Cluster
  access is an IAM-auditable access entry, not a line in the `aws-auth`
  ConfigMap, and whoever runs `apply` does not silently become cluster admin.

Both security groups live here rather than in `eks-nodes`. The control plane and
the kubelet reference each other, so splitting the pair across modules creates a
dependency cycle. The rule that lets nodes reach the VPC endpoints is wired in
the root module for the same reason.
