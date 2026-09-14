# Kubernetes Explorer

Autonomous-SRE embeds [Headlamp](https://headlamp.dev/) at `/kubernetes/` to inspect and operate the cluster without replacing the incident dashboard.

## Access

The protected deployment uses Headlamp's in-cluster ServiceAccount token automatically. No token copy/paste is required.

From the repository root, run:

```bash
make headlamp
```

The command reads the generated platform FQDN, verifies that the protected route is reachable from the current operator network and opens:

```text
https://<platform-fqdn>/kubernetes/
```

If the route is not reachable, check the current public IP, the Scaleway operator CIDR, the Gateway and the HTTPRoute.

## Permission model

The token belongs to the dedicated `sre-system/headlamp` ServiceAccount. It can read common Kubernetes resources across the cluster, including nodes, workloads, events, logs, networking, Argo and Prometheus resources. Kubernetes Secrets and RBAC objects are excluded.

Interactive actions are limited to the `demo` namespace:

- delete a Pod to trigger a controlled restart;
- open a terminal in a demo Pod;
- update or scale Deployments and StatefulSets.

The Headlamp ServiceAccount is deliberately not `cluster-admin`. Access is additionally restricted by the operator-only HTTPS Gateway and Scaleway Security Group.
