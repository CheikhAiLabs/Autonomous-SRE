from autonomous_sre.models import Diagnosis, Evidence, Risk
from autonomous_sre.planner import build_plan


def test_planner_uses_alert_annotations():
    evidence = Evidence(
        alert_name="High5xxRate",
        annotations={
            "sre.action": "rollback_deployment",
            "sre.risk": "high",
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
        labels={"namespace": "demo", "deployment": "demo-service"},
        annotations={"sre.replicas": "8"},
    )
    diagnosis = Diagnosis(
        probable_cause="capacity pressure",
        confidence=0.9,
        recommended_action="scale_deployment_extended",
        recommended_parameters={"replicas": 3},
    )
    plan = build_plan(evidence, diagnosis)
    assert plan is not None
    assert plan.risk == Risk.MEDIUM
    assert plan.parameters["replicas"] == 8


def test_planner_can_use_ai_recommendation_without_sre_action():
    evidence = Evidence(
        alert_name="High5xxRate",
        labels={"namespace": "demo", "deployment": "checkout-api"},
    )
    diagnosis = Diagnosis(
        probable_cause="bad release",
        confidence=0.93,
        recommended_action="rollback_deployment",
    )
    plan = build_plan(evidence, diagnosis)
    assert plan is not None
    assert plan.action == "rollback_deployment"
    assert plan.target_name == "checkout-api"
    assert plan.target_kind == "Deployment"
    assert plan.risk == Risk.LOW


def test_node_action_targets_node_without_namespace_annotation():
    evidence = Evidence(
        alert_name="NodeSchedulingDisabled",
        labels={"node": "worker-02"},
    )
    diagnosis = Diagnosis(
        probable_cause="node left cordoned after maintenance",
        confidence=0.95,
        recommended_action="uncordon_node",
    )
    plan = build_plan(evidence, diagnosis)
    assert plan is not None
    assert plan.target_kind == "Node"
    assert plan.target_name == "worker-02"
    assert plan.namespace == "cluster"
    assert plan.risk == Risk.MEDIUM


def test_unknown_ai_action_is_rejected():
    evidence = Evidence(
        alert_name="MysteryIncident",
        labels={"namespace": "demo", "deployment": "demo-service"},
    )
    diagnosis = Diagnosis(
        probable_cause="unknown",
        confidence=0.6,
        recommended_action="delete_everything",
    )
    assert build_plan(evidence, diagnosis) is None
