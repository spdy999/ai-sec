# eks-nodes

A managed node group and the launch template that hardens the hosts under it.

The control that carries this module is three lines:

```hcl
http_tokens                 = "required"
http_put_response_hop_limit = 1
```

IMDSv2 only, and the metadata request dies at the container boundary. Without
it, any pod that can make an HTTP request reads the node role's credentials from
`169.254.169.254`, and workload identity becomes theatre — the attacker simply
takes the node's identity instead of the pod's.

The node role itself carries only what the kubelet needs: pull images, join the
cluster, manage ENIs. It has no Bedrock access and no S3 access. Those belong to
the workload identity, not to the host that happens to run it.
