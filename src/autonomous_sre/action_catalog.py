from functools import lru_cache
from pathlib import Path

import yaml

from autonomous_sre.config import get_settings
from autonomous_sre.models import RemediationPlan, Risk


def _catalog_path() -> Path:
    configured_path = Path(get_settings().action_catalog_path)
    if configured_path.exists():
        return configured_path
    return Path(__file__).resolve().parents[2] / "remediation" / "catalog.yaml"


@lru_cache
def load_catalog() -> dict[str, dict[str, object]]:
    path = _catalog_path()
    data = yaml.safe_load(path.read_text())
    actions = data.get("actions") if isinstance(data, dict) else None
    if not isinstance(actions, dict):
        raise ValueError(f"Invalid remediation catalog at {path}")
    return actions


def get_action_rule(action: str) -> dict[str, object]:
    catalog = load_catalog()
    if action not in catalog:
        raise ValueError(f"Action {action!r} is not in the remediation catalog")
    return catalog[action]


def safe_action_descriptions() -> dict[str, dict[str, object]]:
    return {
        action: rule
        for action, rule in load_catalog().items()
        if str(rule.get("risk")) != Risk.FORBIDDEN.value
    }


def validate_plan(plan: RemediationPlan) -> None:
    rule = get_action_rule(plan.action)
    catalog_risk = Risk(str(rule["risk"]))
    if plan.risk != catalog_risk:
        raise ValueError("Plan risk does not match the immutable action catalog")
    max_blast_radius = int(rule.get("max_blast_radius", 0))
    if plan.blast_radius > max_blast_radius:
        raise ValueError("Requested blast radius exceeds the catalog limit")
