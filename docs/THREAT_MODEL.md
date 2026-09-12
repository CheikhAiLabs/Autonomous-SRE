# Threat model

## Assets

- Scaleway infrastructure credentials
- Kubernetes credentials
- remediation authority
- incident and telemetry data
- SMTP credential
- GitHub deployment environment

## Primary threats

### Prompt injection through logs or traces

Logs, labels and trace payloads are treated as untrusted evidence. The model cannot execute commands and can only emit a typed diagnosis. Remediation is selected from a fixed catalog and re-authorized by OPA.

### Model compromise or hallucination

The LLM is not a policy decision point. OPA and static catalog validation are authoritative.

### Controller compromise

The controller receives limited Kubernetes RBAC and cannot delete namespaces or mutate infrastructure/IAM.

### Approval-link prefetch

The emailed link only opens the review page. A state-changing POST with the short-lived signed token is required.

### CI compromise

Production secrets are scoped to the GitHub `production` environment. Builds run on GitHub-hosted runners; infrastructure deployment runs on a dedicated Scaleway self-hosted runner.

### Cluster-wide outage

This first version runs the SRE control plane in the monitored cluster. A future hardening step is to move the SRE control plane into a separate management cluster while keeping this repository topology-compatible.
