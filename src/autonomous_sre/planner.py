from __future__ import annotations

from autonomous_sre.models import Diagnosis, Evidence, RemediationPlan, Risk


def build_plan(evidence: Evidence, diagnosis: Diagnosis) -> RemediationPlan | None:
    action = evidence.annotations.get("sre.action")
    if not action:
        return None

    namespace = evidence.annotations.get("sre.target_namespace") or evidence.labels.get(
        "namespace", "demo"
    )
    target_name = evidence.annotations.get("sre.target_name") or evidence.labels.get(
        "deployment", ""
    )
    target_kind = evidence.annotations.get("sre.target_kind", "Deployment")
    risk = Risk(evidence.annotations.get("sre.risk", "medium"))
    blast_radius = int(evidence.annotations.get("sre.blast_radius", "1"))

    if not target_name:
        return None

    parameters: dict[str, object] = {}
    if action in {"scale_deployment", "scale_deployment_extended"}:
        parameters["replicas"] = int(evidence.annotations.get("sre.replicas", "2"))

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
