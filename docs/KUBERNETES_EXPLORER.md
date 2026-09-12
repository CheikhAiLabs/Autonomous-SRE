# Kubernetes Explorer

Autonomous-SRE embeds [Headlamp](https://headlamp.dev/) at `/kubernetes/` to inspect and operate the cluster without replacing the incident dashboard.

## Access

Refresh the local kubeconfig, generate an eight-hour login token, then paste the token into Headlamp:

```bash
./scripts/fetch-kubeconfig.sh
make headlamp-token
```

Open `https://<platform-fqdn>/kubernetes/`.

## Permission model

The token belongs to the dedicated `sre-system/headlamp` ServiceAccount. It can read common Kubernetes resources across the cluster, including nodes, workloads, events, logs, networking, Argo and Prometheus resources. Kubernetes Secrets and RBAC objects are excluded.

Interactive actions are limited to the `demo` namespace:

- delete a Pod to trigger a controlled restart;
- open a terminal in a demo Pod;
- update or scale Deployments and StatefulSets.

Headlamp's unsafe ServiceAccount auto-login is disabled. Every browser session must authenticate with a temporary token. Do not replace this role with `cluster-admin`.
