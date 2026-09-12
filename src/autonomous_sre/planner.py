from __future__ import annotations

from autonomous_sre.action_catalog import get_action_rule
from autonomous_sre.models import (
    Diagnosis,
    Evidence,
    RemediationPlan,
    Risk,
)

SCALING_ACTIONS = {
    "scale_deployment",
    "scale_deployment_extended",
    "scale_statefulset",
}

ACTION_TARGETS = {
    "restart_deployment": ("Deployment", "deployment"),
    "rollback_deployment": ("Deployment", "deployment"),
    "scale_deployment": ("Deployment", "deployment"),
    "scale_deployment_extended": ("Deployment", "deployment"),
    "replace_single_pod": ("Pod", "pod"),
    "restart_statefulset": ("StatefulSet", "statefulset"),
    "scale_statefulset": ("StatefulSet", "statefulset"),
    "restart_daemonset": ("DaemonSet", "daemonset"),
    "uncordon_node": ("Node", "node"),
    "cordon_node": ("Node", "node"),
}


def _annotation(evidence: Evidence, name: str) -> str | None:
    """Read both dotted and underscore SRE annotation conventions.

    PrometheusRule annotations in the deployed manifests use keys such as
    ``sre_action`` while older planner code expected ``sre.action``. Supporting
    both keeps existing alerts compatible and avoids silently dropping a safe
    remediation plan.
    """

    return evidence.annotations.get(name) or evidence.annotations.get(name.replace(".", "_"))


def build_plan(evidence: Evidence, diagnosis: Diagnosis) -> RemediationPlan | None:
    action = _annotation(evidence, "sre.action") or diagnosis.recommended_action
    if not action:
        return None

    try:
        rule = get_action_rule(action)
    except ValueError:
        return None

    risk = Risk(str(rule["risk"]))
    max_blast_radius = int(rule.get("max_blast_radius", 1))
    requested_blast_radius = int(_annotation(evidence, "sre.blast_radius") or "1")
    blast_radius = min(requested_blast_radius, max_blast_radius)

    expected_kind, label_key = ACTION_TARGETS.get(action, ("Deployment", "deployment"))
    target_kind = _annotation(evidence, "sre.target_kind") or expected_kind
    target_name = _annotation(evidence, "sre.target_name") or evidence.labels.get(label_key, "")

    namespace = _annotation(evidence, "sre.target_namespace") or evidence.labels.get(
        "namespace", "cluster" if target_kind == "Node" else "demo"
    )

    if not target_name:
        return None

    parameters = dict(diagnosis.recommended_parameters)
    if action in SCALING_ACTIONS:
        requested_replicas = _annotation(evidence, "sre.replicas")
        if requested_replicas is not None:
            parameters["replicas"] = int(requested_replicas)
        elif "replicas" not in parameters:
            parameters["replicas"] = 2

    verification_query = _annotation(evidence, "sre.verify_query")
    verification_threshold = _annotation(evidence, "sre.verify_threshold")

    return RemediationPlan(
        action=action,
        risk=risk,
        namespace=namespace,
        target_kind=target_kind,
        target_name=target_name,
        parameters=parameters,
        blast_radius=blast_radius,
        verification_query=verification_query,
        verification_threshold=(
            float(verification_threshold) if verification_threshold is not None else None
        ),
    )
