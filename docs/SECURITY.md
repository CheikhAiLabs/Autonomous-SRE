# Security

## Primary controls

1. Scaleway Security Groups default to inbound deny.
2. K3s API and SSH accept traffic only from the operator CIDR and runner CIDR.
3. Cilium provides the CNI and Kubernetes network-policy enforcement.
4. The controller ServiceAccount only receives the Kubernetes verbs required for the implemented safe actions.
5. OPA policies are evaluated both before publishing an autonomous request and again in the execution controller.
6. The action catalog defines immutable risk and blast-radius ceilings.
7. Approval links contain signed, short-lived tokens; opening the link does not execute anything.
8. Secrets remain outside Git and are injected through GitHub Environment secrets and Kubernetes Secrets.
9. CI scans source and images, emits SBOMs and signs release images with Cosign.
10. Tetragon and Kubernetes audit logging provide runtime and API visibility.

## Intentionally unsupported autonomous operations

- arbitrary shell commands
- namespace deletion
- OpenTofu destroy
- IAM/key mutation
- secret changes
- destructive database operations
- broad node drain

Those operations are outside the initial executor identity.
