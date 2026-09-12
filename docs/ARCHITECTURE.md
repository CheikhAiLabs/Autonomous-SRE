# Architecture

Autonomous-SRE deliberately separates sensing, reasoning, authorization and execution.

## Data plane

The Kubernetes cluster runs on Scaleway Compute VMs and uses a private Scaleway VPC network for node-to-node traffic. Public addresses remain attached for controlled administration and outbound access. Security Groups only expose SSH and the Kubernetes API to the operator and deployment runner. Dashboard HTTPS is operator-CIDR restricted.

K3s is configured without Flannel or the built-in network policy controller. Cilium is installed as the CNI with Hubble and Gateway API enabled.

## Observability plane

OpenTelemetry, Prometheus, Loki, Tempo, Hubble and Tetragon provide telemetry and runtime evidence.

Prometheus alerts intended for autonomous handling carry explicit `sre.*` annotations. Those annotations identify the target, suggested action, immutable risk level and optional verification query.

## Control plane

- Incident worker: polls firing Prometheus alerts, deduplicates incidents and builds evidence.
- Local reasoner: Ollama-hosted Qwen3 model generates a structured diagnosis.
- Planner: converts the diagnosis plus deterministic alert metadata into a typed remediation plan.
- OPA: decides allow, require_approval or deny.
- Remediation controller: maps the approved action name to a fixed Kubernetes API implementation.
- API: exposes incidents and approval endpoints.
- Dashboard: visualizes incident state and performs explicit approval/rejection POSTs.
- NATS: transports remediation events and results.
- PostgreSQL: persists incident history and audit data.

## Safety property

There is no `bash(command_from_model)` path in the architecture.
