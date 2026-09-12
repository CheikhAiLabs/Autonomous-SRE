from autonomous_sre.models import Diagnosis, Evidence, Risk
from autonomous_sre.planner import build_plan


def test_planner_uses_alert_annotations():
    evidence = Evidence(
        alert_name="High5xxRate",
        annotations={
            "sre.action": "rollback_deployment",
            "sre.risk": "low",
            "sre.target_namespace": "demo",
            "sre.target_kind": "Deployment",
            "sre.target_name": "demo-service",
            "sre.blast_radius": "1",
        },
    )
    diagnosis = Diagnosis(probable_cause="bad release", confidence=0.9)
    plan = build_plan(evidence, diagnosis)
    assert plan is not None
    assert plan.action == "rollback_deployment"
    assert plan.risk == Risk.LOW


def test_extended_scale_is_medium_risk():
    evidence = Evidence(
        alert_name="CapacityPressure",
        annotations={
            "sre.action": "scale_deployment_extended",
            "sre.risk": "medium",
            "sre.target_namespace": "demo",
            "sre.target_kind": "Deployment",
            "sre.target_name": "demo-service",
            "sre.replicas": "8",
            "sre.blast_radius": "1",
        },
    )
    diagnosis = Diagnosis(probable_cause="capacity pressure", confidence=0.9)
    plan = build_plan(evidence, diagnosis)
    assert plan is not None
    assert plan.risk == Risk.MEDIUM
    assert plan.parameters["replicas"] == 8
