# Manifests the cluster must refuse

Each file breaks a control on purpose. They exist so the Kubernetes controls can
be proven to reject bad input, the same way the insecure Terraform fixture
proves the policy gate rejects bad infrastructure.

A control that has only ever been shown accepting good input has not been
tested.

**Never apply these to a real cluster.** They are applied only inside the
pipeline, against a kind cluster `security.yml` creates for that job and throws
away with the runner.

| File | Breaks |
|---|---|
| `privileged-pod.yaml` | Pod Security restricted: privileged, root, host namespaces, writable root filesystem |
| `wildcard-rbac.yaml` | Least privilege: a ClusterRole granting `*` on `*` |
| `public-image.yaml` | Supply chain: mutable tag from a public registry, no resource limits |
| `default-identity-pod.yaml` | Workload identity: default service account with an automounted API token |
| `unlabelled-namespace.yaml` | Pod Security admission: no enforce label, so the namespace runs privileged |
| `unannotated-serviceaccount.yaml` | Workload identity: no IRSA role annotation, so pods inherit the node identity |
| `open-egress-networkpolicy.yaml` | Egress: a NetworkPolicy that allows 0.0.0.0/0, undoing default-deny |

`privileged-pod.yaml` is applied against a real API server in the pipeline's
workload gate, which requires the apply to fail with `violates PodSecurity`.
Every file here, that one included, is refused by the static gate
(`make policy-k8s-negative`), and for the last three that is the only refusal
available: a cluster accepts all three without complaint, which is the point —
an unlabelled namespace and an over-broad NetworkPolicy are valid Kubernetes
and invalid here.
