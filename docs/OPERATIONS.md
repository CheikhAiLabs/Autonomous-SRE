# Operations

## Configuration

`make configure` is the only expected operator-specific bootstrap step. It creates ignored files under `config/` and auto-detects the Scaleway project and operator public IP when possible.

## Full reconstruction

```bash
make destroy-all
make deploy-all
make verify
```

The remote state bucket is intentionally preserved by destroy commands.

## Normal deployment

```bash
make deploy
```

## Chaos validation

```bash
make chaos-smoke
make chaos-bad-release
```

The bad-release test should produce a Prometheus alert and an autonomous rollback.
