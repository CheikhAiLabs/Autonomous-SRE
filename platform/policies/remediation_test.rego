package autonomous_sre.remediation_test
import rego.v1
import data.autonomous_sre.remediation

test_low_risk_rollback_allowed if {
  remediation.decision with input as {
    "mode": "autonomous-low-risk",
    "action": "rollback_deployment",
    "risk": "low",
    "namespace": "demo",
    "blast_radius": 1
  } == {"result": "allow", "reason": "Guardrailed low/medium-risk action is permitted in autonomous mode"}
}

test_medium_risk_scaling_allowed if {
  remediation.decision with input as {
    "mode": "autonomous-low-risk",
    "action": "scale_deployment_extended",
    "risk": "medium",
    "namespace": "demo",
    "blast_radius": 3
  } == {"result": "allow", "reason": "Guardrailed low/medium-risk action is permitted in autonomous mode"}
}

test_high_risk_cordon_requires_approval if {
  remediation.decision with input as {
    "mode": "autonomous-low-risk",
    "action": "cordon_node",
    "risk": "high",
    "namespace": "demo",
    "blast_radius": 1
  } == {"result": "require_approval", "reason": "High-impact remediation requires explicit operator approval"}
}

test_protected_namespace_denied if {
  remediation.decision with input as {
    "mode": "autonomous-low-risk",
    "action": "restart_deployment",
    "risk": "low",
    "namespace": "kube-system",
    "blast_radius": 1
  } == {"result": "deny", "reason": "Autonomous remediation cannot target protected namespaces"}
}

test_destroy_denied if {
  remediation.decision with input as {
    "mode": "approved",
    "action": "destroy_infrastructure",
    "risk": "forbidden",
    "namespace": "demo",
    "blast_radius": 0
  } == {"result": "deny", "reason": "Action is explicitly forbidden"}
}

test_drain_denied_even_if_approved if {
  remediation.decision with input as {
    "mode": "approved",
    "action": "drain_node",
    "risk": "forbidden",
    "namespace": "demo",
    "blast_radius": 0
  } == {"result": "deny", "reason": "Action is explicitly forbidden"}
}
