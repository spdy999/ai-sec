# Manifests the cluster must refuse

Each file breaks a control on purpose. They exist so the Kubernetes controls can
be proven to reject bad input, the same way the insecure Terraform fixture
proves the policy gate rejects bad infrastructure.

A control that has only ever been shown accepting good input has not been
tested.

**Never apply these to a real cluster.** Every target that uses them pins
`--context kind-koerber-demo` explicitly and never relies on the current
kubectl context.

| File | Breaks |
|---|---|
| `privileged-pod.yaml` | Pod Security restricted: privileged, root, host namespaces, writable root filesystem |
| `wildcard-rbac.yaml` | Least privilege: a ClusterRole granting `*` on `*` |
| `public-image.yaml` | Supply chain: mutable tag from a public registry, no resource limits |
| `default-identity-pod.yaml` | Workload identity: default service account with an automounted API token |
