SHELL := /bin/bash
.DEFAULT_GOAL := help

.PHONY: help init configure check fmt test plan deploy deploy-all deploy-ci verify status logs chaos-smoke chaos-bad-release access destroy destroy-all

help:
	@echo "Autonomous-SRE"
	@echo
	@echo "  make init               Initialize/create the GitHub repository safely"
	@echo "  make configure          Create/update portable local config"
	@echo "  make check              Run local static checks"
	@echo "  make fmt                Format Python and OpenTofu"
	@echo "  make test               Run Python and OPA tests"
	@echo "  make plan               Plan runner + platform OpenTofu stacks"
	@echo "  make deploy-all         Bootstrap runner and deploy the full platform"
	@echo "  make deploy             Deploy using the existing GitHub runner"
	@echo "  make verify             Run end-to-end verification"
	@echo "  make status             Show cluster and SRE status"
	@echo "  make logs               Follow Autonomous-SRE logs"
	@echo "  make chaos-smoke        Run safe Pod kill scenario"
	@echo "  make chaos-bad-release  Run the autonomous rollback scenario"
	@echo "  make access             Refresh operator CIDR"
	@echo "  make destroy            Destroy platform, keep runner/state bucket"
	@echo "  make destroy-all        Destroy platform + runner + state bucket"

init:
	@./scripts/configure.sh
	@./scripts/init-repository.sh

configure:
	@./scripts/configure.sh

check:
	@./scripts/check.sh

fmt:
	@ruff format src apps/api apps/worker apps/controller tests workloads/demo-service
	@ruff check --fix src apps/api apps/worker apps/controller tests workloads/demo-service
	@tofu -chdir=infrastructure/opentofu-runner fmt -recursive
	@tofu -chdir=infrastructure/opentofu-platform fmt -recursive

test:
	@uv run pytest -q
	@if command -v opa >/dev/null 2>&1; then opa test platform/policies -v; else echo "opa not installed locally; CI will run policy tests"; fi

plan:
	@./scripts/plan.sh

deploy-all:
	@./scripts/deploy-all.sh

deploy:
	@./scripts/deploy.sh

deploy-ci:
	@./scripts/deploy-ci.sh

verify:
	@./scripts/verify.sh

status:
	@./scripts/status.sh

logs:
	@./scripts/logs.sh

chaos-smoke:
	@./scripts/chaos.sh pod-kill

chaos-bad-release:
	@./scripts/chaos.sh bad-release

access:
	@./scripts/access.sh

destroy:
	@./scripts/destroy.sh

destroy-all:
	@./scripts/destroy-all.sh
