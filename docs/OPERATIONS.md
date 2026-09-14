# Operations

## Configuration

`make configure` is the operator bootstrap step. It creates ignored files under `config/` and detects the Scaleway project and operator public IP when possible.

## Full reconstruction

Use this sequence to remove and recreate the complete environment:

```bash
make destroy-all
make deploy-all
make verify
```

`make destroy-all` requires the confirmation `DESTROY-ALL`. It removes the Kubernetes platform, temporary build runners, the persistent GitHub Actions runner and the Scaleway Object Storage state bucket.

`make deploy-all` recreates the remote state bucket, provisions and registers the persistent runner, builds the images and deploys the full platform.

If you want to remove only the Kubernetes platform while preserving the runner and remote state, use:

```bash
make destroy
```

## Normal deployment

For a release with the existing runner:

```bash
make deploy
```

## Verification and status

```bash
make verify
make status
make logs
```

## Kubernetes Explorer

```bash
make headlamp
```

The command checks that the protected Headlamp route is reachable and opens it in the default browser.

## Chaos validation

```bash
make chaos-smoke
make chaos-replica-floor
make chaos-bad-release
```

The native smoke test checks Kubernetes self-healing. The two managed scenarios exercise autonomous scaling and rollback, including cleanup when a test is interrupted.
