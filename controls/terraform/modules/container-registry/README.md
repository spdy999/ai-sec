# container-registry

The only place the cluster can pull an image from.

This VPC has no route to Docker Hub, Quay or ghcr.io. An image runs here
because it was pushed through this repository, which means it was scanned on
push and is addressed by a digest.

Three properties carry the control:

**Immutable tags.** A tag that can be repointed after review means the artefact
that was reviewed and the artefact that runs are different things, and nothing
in the audit trail says so.

**A customer-managed key.** ECR's default is an AWS-owned key: not auditable,
not revocable, and not usable as evidence that layers were encrypted under a
key this organisation controls.

**Pull granted to named principals.** The repository policy lists the node role.
An identity that can reach the ECR endpoint but is not on that list gets
nothing, so a compromised pod in another namespace cannot read the image it
would need in order to study it.

The deny on `aws:SecureTransport` is at the resource rather than the network,
for the same reason the corpus bucket carries one: a network control proves
nothing when the object is copied somewhere else.
