from __future__ import annotations

import asyncio
from datetime import datetime, timezone
from typing import Any

from kubernetes import client, config
from autonomous_sre.action_catalog import validate_plan
from autonomous_sre.models import RemediationPlan


class KubernetesExecutor:
    def __init__(self) -> None:
        try:
            config.load_incluster_config()
        except config.ConfigException:
            config.load_kube_config()
        self.apps = client.AppsV1Api()
        self.core = client.CoreV1Api()

    async def execute(self, plan: RemediationPlan) -> dict[str, Any]:
        validate_plan(plan)
        mapping = {
            "restart_deployment": self._restart_deployment,
            "rollback_deployment": self._rollback_deployment,
            "scale_deployment": self._scale_deployment,
            "scale_deployment_extended": self._scale_deployment_extended,
            "replace_single_pod": self._replace_single_pod,
        }
        if plan.action not in mapping:
            raise ValueError(f"Action {plan.action!r} is not implemented by this controller")
        return await asyncio.to_thread(mapping[plan.action], plan)

    def _restart_deployment(self, plan: RemediationPlan) -> dict[str, Any]:
        stamp = datetime.now(timezone.utc).isoformat()
        body = {
            "spec": {
                "template": {
                    "metadata": {
                        "annotations": {"autonomous-sre/restarted-at": stamp}
                    }
                }
            }
        }
        self.apps.patch_namespaced_deployment(plan.target_name, plan.namespace, body)
        return {"action": plan.action, "timestamp": stamp}

    def _scale_deployment(self, plan: RemediationPlan) -> dict[str, Any]:
        replicas = int(plan.parameters["replicas"])
        if not 1 <= replicas <= 6:
            raise ValueError("Autonomous scaling is hard limited to 1..6 replicas")
        body = {"spec": {"replicas": replicas}}
        self.apps.patch_namespaced_deployment_scale(plan.target_name, plan.namespace, body)
        return {"action": plan.action, "replicas": replicas}

    def _scale_deployment_extended(self, plan: RemediationPlan) -> dict[str, Any]:
        replicas = int(plan.parameters["replicas"])
        if not 1 <= replicas <= 10:
            raise ValueError("Approved scaling is hard limited to 1..10 replicas")
        body = {"spec": {"replicas": replicas}}
        self.apps.patch_namespaced_deployment_scale(plan.target_name, plan.namespace, body)
        return {"action": plan.action, "replicas": replicas}

    def _replace_single_pod(self, plan: RemediationPlan) -> dict[str, Any]:
        pod = self.core.read_namespaced_pod(plan.target_name, plan.namespace)
        owners = pod.metadata.owner_references or []
        if not owners:
            raise ValueError("Refusing to delete a standalone Pod")
        self.core.delete_namespaced_pod(plan.target_name, plan.namespace, grace_period_seconds=30)
        return {"action": plan.action, "pod": plan.target_name}

    def _rollback_deployment(self, plan: RemediationPlan) -> dict[str, Any]:
        deployment = self.apps.read_namespaced_deployment(plan.target_name, plan.namespace)
        selector = deployment.spec.selector.match_labels or {}
        label_selector = ",".join(f"{k}={v}" for k, v in selector.items())
        replicasets = self.apps.list_namespaced_replica_set(
            plan.namespace, label_selector=label_selector
        ).items

        owned = []
        for rs in replicasets:
            owners = rs.metadata.owner_references or []
            if any(o.uid == deployment.metadata.uid for o in owners):
                revision = int((rs.metadata.annotations or {}).get("deployment.kubernetes.io/revision", "0"))
                owned.append((revision, rs))
        owned.sort(key=lambda item: item[0], reverse=True)
        if len(owned) < 2:
            raise ValueError("No previous Deployment revision is available")

        current_revision = owned[0][0]
        previous_revision, previous_rs = owned[1]
        previous_template = previous_rs.spec.template.to_dict()
        metadata = previous_template.setdefault("metadata", {})
        annotations = metadata.setdefault("annotations", {}) or {}
        annotations["autonomous-sre/rollback-from-revision"] = str(current_revision)
        annotations["autonomous-sre/rollback-at"] = datetime.now(timezone.utc).isoformat()
        metadata["annotations"] = annotations

        self.apps.patch_namespaced_deployment(
            plan.target_name,
            plan.namespace,
            {"spec": {"template": previous_template}},
        )
        return {
            "action": plan.action,
            "from_revision": current_revision,
            "to_revision": previous_revision,
        }
