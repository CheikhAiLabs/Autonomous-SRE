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


def build_plan(evidence: Evidence, diagnosis: Diagnosis) -> RemediationPlan | None:
    action = evidence.annotations.get("sre.action") or diagnosis.recommended_action
    if not action:
        return None

    try:
        rule = get_action_rule(action)
    except ValueError:
        return None

    risk = Risk(str(rule["risk"]))
    max_blast_radius = int(rule.get("max_blast_radius", 1))
    requested_blast_radius = int(evidence.annotations.get("sre.blast_radius", "1"))
    blast_radius = min(requested_blast_radius, max_blast_radius)

    expected_kind, label_key = ACTION_TARGETS.get(action, ("Deployment", "deployment"))
    target_kind = evidence.annotations.get("sre.target_kind", expected_kind)
    target_name = evidence.annotations.get("sre.target_name") or evidence.labels.get(label_key, "")

    namespace = evidence.annotations.get("sre.target_namespace") or evidence.labels.get(
        "namespace", "cluster" if target_kind == "Node" else "demo"
    )

    if not target_name:
        return None

    parameters = dict(diagnosis.recommended_parameters)
    if action in SCALING_ACTIONS:
        if "sre.replicas" in evidence.annotations:
            parameters["replicas"] = int(evidence.annotations["sre.replicas"])
        elif "replicas" not in parameters:
            parameters["replicas"] = 2

    return RemediationPlan(
        action=action,
        risk=risk,
        namespace=namespace,
        target_kind=target_kind,
        target_name=target_name,
        parameters=parameters,
        blast_radius=blast_radius,
        verification_query=evidence.annotations.get("sre.verify_query"),
        verification_threshold=(
            float(evidence.annotations["sre.verify_threshold"])
            if "sre.verify_threshold" in evidence.annotations
            else None
        ),
    )
