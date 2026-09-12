# Autonomous-SRE

Private, open-source autonomous SRE platform for Kubernetes on Scaleway.

Autonomous-SRE continuously observes a Kubernetes environment, detects incidents, correlates telemetry, builds an evidence bundle, uses a local open-source model to reason about likely root cause, applies policy-as-code, executes only approved remediations, verifies recovery, and requests human approval only when the action crosses a configured risk threshold.

The default alert recipient is `cheikhminator@gmail.com`. It is intentionally configurable so another operator can reuse the project with a different email and a different Scaleway Project ID.

## Core goals

- Maximum safe autonomy, not blind automation.
- No proprietary LLM API and no paid SaaS dependency in the runtime path.
- Kubernetes runs on Scaleway Compute VMs rather than a managed Kubernetes service.
- Open-source components only, except GitHub as the source-control/CI platform and Scaleway as the infrastructure provider.
- All infrastructure and platform deployment driven by Make, OpenTofu, Ansible, Helm and GitHub Actions.
- Low-risk remediations can run automatically.
- Medium/high-risk remediations require approval.
- Destructive actions are denied by policy.
- Every automated action is auditable and followed by a post-remediation verification step.

## Architecture

```text
GitHub
  │
  ├── CI / security / image build workflows
  │
  └── persistent self-hosted runner on Scaleway
            │
            ▼
       OpenTofu + Ansible
            │
            ▼
      Scaleway VM Kubernetes cluster
            │
            ├── Cilium + Hubble + Gateway API
            ├── OpenTelemetry Collector
            ├── Prometheus + Alertmanager + Grafana
            ├── Loki + Tempo
            ├── Tetragon
            ├── NATS JetStream
            ├── PostgreSQL
            ├── OPA
            ├── Argo CD + Argo Rollouts
            ├── Chaos Mesh
            ├── Ollama + Qwen3
            ├── Autonomous-SRE API
            ├── Incident worker
            ├── Remediation controller
            ├── SRE dashboard
            └── demo workloads / chaos scenarios
```

## Decision flow

```text
Observe
  ↓
Detect
  ↓
Correlate
  ↓
Build evidence
  ↓
Local AI diagnosis
  ↓
Structured remediation proposal
  ↓
OPA policy decision
  ├── ALLOW -> execute automatically
  ├── REQUIRE_APPROVAL -> email + dashboard approval
  └── DENY -> block and audit
  ↓
Verify recovery
  ↓
Close incident or roll back / escalate
```

The model never receives unrestricted shell access. The remediation controller exposes a fixed action catalog and uses Kubernetes APIs directly.

## Default risk model

| Risk | Example | Behavior |
|---|---|---|
| LOW | restart one Deployment, replace one unhealthy Pod, rollback last bad Deployment revision, small replica change | automatic |
| MEDIUM | larger scale change, selected config remediation | approval if policy requires it |
| HIGH | node-level or wide-scope change | approval/manual |
| FORBIDDEN | namespace deletion, infrastructure destruction, secret/IAM mutation, destructive database operations | denied |

## Open-source stack

- OpenTofu
- Ansible
- K3s
- Cilium + Hubble
- Kubernetes Gateway API
- OpenTelemetry
- Prometheus + Alertmanager + Grafana
- Loki
- Tempo
- Tetragon
- NATS JetStream
- PostgreSQL
- Open Policy Agent
- Argo CD
- Argo Rollouts
- Chaos Mesh
- Ollama
- Qwen3
- FastAPI
- React + TypeScript + Vite
- Trivy, Syft, Cosign, Ruff, Pytest, OPA tests

## Production-oriented defaults

- Scaleway Security Groups default-deny inbound traffic.
- Kubernetes API and SSH are restricted to the operator CIDR and deployment-runner CIDR.
- The web Gateway is restricted to the operator CIDR by default.
- Cilium is used as the CNI and Gateway API implementation.
- Internal service access is controlled with Kubernetes NetworkPolicies.
- The remediation controller uses a dedicated ServiceAccount and intentionally limited RBAC.
- Secrets are generated locally and stored outside Git.
- GitHub Actions receives secrets through the `production` environment.
- OpenTofu state is stored in versioned Scaleway Object Storage.
- Images are built in GitHub Actions, scanned, given SBOMs and signed with keyless Cosign.

## First deployment

### Local prerequisites

The workstation needs:

- macOS or Linux
- `git`
- `make`
- `gh`
- `scw`
- `tofu` >= 1.12
- `jq`
- `curl`
- `ssh`

Authenticate once:

```bash
gh auth login
scw login
```

Then:

```bash
make configure
make deploy-all
```

`make configure`:

- detects the Scaleway Project ID from `scw config get default-project-id` if not explicitly set,
- detects the operator public IP,
- defaults `ALERT_EMAIL` to `cheikhminator@gmail.com`,
- creates local ignored configuration files,
- generates approval-signing and PostgreSQL secrets,
- optionally records SMTP credentials for email delivery.

`make deploy-all`:

1. bootstraps the remote OpenTofu state bucket,
2. creates or reconciles the persistent GitHub runner,
3. configures the GitHub `production` environment,
4. runs the image build workflow,
5. deploys the Scaleway platform through the self-hosted runner,
6. installs K3s, Cilium and the platform stack,
7. deploys the Autonomous-SRE services and demo workloads,
8. verifies cluster and application health,
9. prints the dashboard URL.

## Configuration portability

Operator-specific values live in ignored local files.

```text
config/project.env
config/secrets.env
```

The template is committed as:

```text
config/project.env.example
config/secrets.env.example
```

Important portable settings include:

```bash
SCW_PROJECT_ID=
ALERT_EMAIL=cheikhminator@gmail.com
OPERATOR_CIDR=auto
SCW_REGION=fr-par
SCW_ZONE=fr-par-1
CONTROL_PLANE_TYPE=DEV1-L
WORKER_TYPE=DEV1-XL
WORKER_COUNT=2
RUNNER_TYPE=DEV1-S
AUTO_REMEDIATION_MODE=autonomous-low-risk
OLLAMA_MODEL=qwen3:4b
```

A different user can clone the repository, run `make configure`, and use their own Scaleway project and email address without modifying committed files.

## Email alerts and approvals

Autonomous-SRE sends enriched incident notifications through SMTP. Gmail works with an App Password and does not require a paid plan.

The receiver is configured by `ALERT_EMAIL`. SMTP credentials belong in `config/secrets.env` and are copied into the GitHub `production` environment during bootstrap.

Low-risk successful remediation email:

```text
INCIDENT RECOVERED AUTOMATICALLY

Root cause: deployment regression
Action: rollback deployment
Result: recovered
No action required.
```

Approval-required email:

```text
MANUAL APPROVAL REQUIRED

Action: medium-risk remediation
Impact: scoped change
Review: https://<cluster-fqdn>/incidents/<id>?token=<short-lived-token>
```

Opening the link never triggers the remediation. Approval is a separate authenticated POST operation protected by a signed, time-limited token.

## Lifecycle

```bash
make configure       # create/update local operator config
make plan            # plan runner and platform stacks
make deploy-all      # runner + full platform
make deploy          # application/platform deployment using existing runner
make verify          # end-to-end checks
make status          # cluster and SRE status
make logs            # SRE service logs
make chaos-smoke     # safe Pod-failure scenario
make chaos-bad-release # golden-path autonomous rollback scenario
make destroy         # destroy platform, keep runner and remote state
make destroy-all     # destroy platform + runner + remote-state bucket
```

## Golden-path chaos scenario

The initial deterministic scenario is a bad application release:

```text
healthy demo service
  ↓
chaos script introduces a high 5xx release
  ↓
Prometheus alert fires
  ↓
incident worker builds evidence
  ↓
AI creates diagnosis + structured remediation proposal
  ↓
OPA classifies rollback as low-risk and allowed
  ↓
controller restores the previous Deployment revision
  ↓
Prometheus confirms error rate recovery
  ↓
incident closes
  ↓
recovery email is sent
```

The project also includes Pod-kill, CPU-stress and network-delay experiments for later validation.

## Repository layout

```text
.
├── .github/workflows/
├── apps/
│   ├── api/
│   ├── controller/
│   ├── worker/
│   └── dashboard/
├── chaos/
├── config/
├── docs/
├── infrastructure/
│   ├── ansible/
│   ├── opentofu-platform/
│   └── opentofu-runner/
├── platform/
│   ├── helmfile/
│   ├── manifests/
│   └── policies/
├── scripts/
├── src/autonomous_sre/
├── tests/
├── workloads/
├── Makefile
└── pyproject.toml
```

## Security boundary

The AI engine can propose actions, but it cannot bypass:

1. Pydantic action-schema validation.
2. Static action catalog validation.
3. OPA policy evaluation.
4. Kubernetes RBAC.
5. Namespace and blast-radius limits.
6. Post-remediation verification.

The project intentionally does not provide the model with a general-purpose Bash executor.

See `docs/SECURITY.md` and `docs/THREAT_MODEL.md` for the detailed security model.

## License

Apache-2.0.

---

*CheikhAiLabs / Autonomous-SRE*
