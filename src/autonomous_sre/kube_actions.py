from __future__ import annotations

import asyncio
from datetime import UTC, datetime
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
            "restart_statefulset": self._restart_statefulset,
            "scale_statefulset": self._scale_statefulset,
            "restart_daemonset": self._restart_daemonset,
            "uncordon_node": self._uncordon_node,
            "cordon_node": self._cordon_node,
        }
        if plan.action not in mapping:
            raise ValueError(f"Action {plan.action!r} is not implemented by this controller")
        return await asyncio.to_thread(mapping[plan.action], plan)

    @staticmethod
    def _restart_annotation() -> dict[str, str]:
        return {"autonomous-sre/restarted-at": datetime.now(UTC).isoformat()}

    def _restart_deployment(self, plan: RemediationPlan) -> dict[str, Any]:
        annotations = self._restart_annotation()
        self.apps.patch_namespaced_deployment(
            plan.target_name,
            plan.namespace,
            {"spec": {"template": {"metadata": {"annotations": annotations}}}},
        )
        return {"action": plan.action, "timestamp": annotations["autonomous-sre/restarted-at"]}

    def _scale_deployment(self, plan: RemediationPlan) -> dict[str, Any]:
        replicas = int(plan.parameters["replicas"])
        if not 1 <= replicas <= 6:
            raise ValueError("Autonomous scaling is hard limited to 1..6 replicas")
        self.apps.patch_namespaced_deployment_scale(
            plan.target_name, plan.namespace, {"spec": {"replicas": replicas}}
        )
        return {"action": plan.action, "replicas": replicas}

    def _scale_deployment_extended(self, plan: RemediationPlan) -> dict[str, Any]:
        replicas = int(plan.parameters["replicas"])
        if not 1 <= replicas <= 10:
            raise ValueError("Extended autonomous scaling is hard limited to 1..10 replicas")
        self.apps.patch_namespaced_deployment_scale(
            plan.target_name, plan.namespace, {"spec": {"replicas": replicas}}
        )
        return {"action": plan.action, "replicas": replicas}

    def _replace_single_pod(self, plan: RemediationPlan) -> dict[str, Any]:
        pod = self.core.read_namespaced_pod(plan.target_name, plan.namespace)
        owners = pod.metadata.owner_references or []
        if not owners:
            raise ValueError("Refusing to delete a standalone Pod")
        self.core.delete_namespaced_pod(
            plan.target_name, plan.namespace, grace_period_seconds=30
        )
        return {"action": plan.action, "pod": plan.target_name}

    def _restart_statefulset(self, plan: RemediationPlan) -> dict[str, Any]:
        annotations = self._restart_annotation()
        self.apps.patch_namespaced_stateful_set(
            plan.target_name,
            plan.namespace,
            {"spec": {"template": {"metadata": {"annotations": annotations}}}},
        )
        return {"action": plan.action, "timestamp": annotations["autonomous-sre/restarted-at"]}

    def _scale_statefulset(self, plan: RemediationPlan) -> dict[str, Any]:
        replicas = int(plan.parameters["replicas"])
        if not 1 <= replicas <= 8:
            raise ValueError("StatefulSet scaling is hard limited to 1..8 replicas")
        self.apps.patch_namespaced_stateful_set_scale(
            plan.target_name, plan.namespace, {"spec": {"replicas": replicas}}
        )
        return {"action": plan.action, "replicas": replicas}

    def _restart_daemonset(self, plan: RemediationPlan) -> dict[str, Any]:
        annotations = self._restart_annotation()
        self.apps.patch_namespaced_daemon_set(
            plan.target_name,
            plan.namespace,
            {"spec": {"template": {"metadata": {"annotations": annotations}}}},
        )
        return {"action": plan.action, "timestamp": annotations["autonomous-sre/restarted-at"]}

    def _uncordon_node(self, plan: RemediationPlan) -> dict[str, Any]:
        self.core.patch_node(plan.target_name, {"spec": {"unschedulable": False}})
        return {"action": plan.action, "node": plan.target_name, "unschedulable": False}

    def _cordon_node(self, plan: RemediationPlan) -> dict[str, Any]:
        self.core.patch_node(plan.target_name, {"spec": {"unschedulable": True}})
        return {"action": plan.action, "node": plan.target_name, "unschedulable": True}

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
                annotations = rs.metadata.annotations or {}
                revision = int(annotations.get("deployment.kubernetes.io/revision", "0"))
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
        annotations["autonomous-sre/rollback-at"] = datetime.now(UTC).isoformat()
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
