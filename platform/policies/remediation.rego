package autonomous_sre.remediation
import rego.v1

default decision := {"result": "deny", "reason": "No policy rule allowed this action"}

autonomous_actions := {
  "restart_deployment",
  "rollback_deployment",
  "scale_deployment",
  "scale_deployment_extended",
  "replace_single_pod",
  "restart_statefulset",
  "scale_statefulset",
  "restart_daemonset",
  "uncordon_node",
}
high_risk_actions := {"cordon_node"}
forbidden_actions := {"delete_namespace", "destroy_infrastructure", "drain_node"}
protected_namespaces := {"kube-system", "sre-system", "monitoring", "argocd", "chaos-mesh"}

decision := {"result": "deny", "reason": "Action is explicitly forbidden"} if {
  input.action in forbidden_actions
}

decision := {"result": "deny", "reason": "Autonomous remediation cannot target protected namespaces"} if {
  input.namespace in protected_namespaces
}

decision := {"result": "allow", "reason": "Guardrailed low/medium-risk action is permitted in autonomous mode"} if {
  input.mode == "autonomous-low-risk"
  input.risk in {"low", "medium"}
  input.action in autonomous_actions
  not input.namespace in protected_namespaces
  input.blast_radius <= 25
}

decision := {"result": "require_approval", "reason": "High-impact remediation requires explicit operator approval"} if {
  input.risk == "high"
  input.action in high_risk_actions
  not input.namespace in protected_namespaces
}

decision := {"result": "allow", "reason": "Operator already approved this remediation"} if {
  input.mode == "approved"
  input.risk != "forbidden"
  not input.action in forbidden_actions
  not input.namespace in protected_namespaces
}
