package autonomous_sre.remediation
import rego.v1

default decision := {"result": "deny", "reason": "No policy rule allowed this action"}

low_risk_actions := {"restart_deployment", "rollback_deployment", "scale_deployment", "replace_single_pod"}
forbidden_actions := {"delete_namespace", "destroy_infrastructure", "drain_node"}
protected_namespaces := {"kube-system", "sre-system", "monitoring", "argocd", "chaos-mesh"}

decision := {"result": "deny", "reason": "Action is explicitly forbidden"} if {
  input.action in forbidden_actions
}

decision := {"result": "deny", "reason": "Autonomous remediation cannot target protected namespaces"} if {
  input.namespace in protected_namespaces
}

decision := {"result": "allow", "reason": "Low-risk action is permitted in autonomous mode"} if {
  input.mode == "autonomous-low-risk"
  input.risk == "low"
  input.action in low_risk_actions
  not input.namespace in protected_namespaces
  input.blast_radius <= 3
}

decision := {"result": "allow", "reason": "Operator already approved this remediation"} if {
  input.mode == "approved"
  input.risk != "forbidden"
  not input.action in forbidden_actions
  not input.namespace in protected_namespaces
}

decision := {"result": "require_approval", "reason": "Risk level requires human approval"} if {
  input.risk in {"medium", "high"}
  not input.action in forbidden_actions
  not input.namespace in protected_namespaces
}
