from __future__ import annotations

import json
from typing import Any

import httpx

from autonomous_sre.action_catalog import safe_action_descriptions
from autonomous_sre.config import get_settings
from autonomous_sre.models import Diagnosis, Evidence


class LocalReasoner:
    def __init__(self) -> None:
        self.settings = get_settings()
        self.client = httpx.AsyncClient(
            base_url=self.settings.ollama_url,
            timeout=self.settings.ollama_timeout_seconds,
        )

    async def diagnose(self, evidence: Evidence) -> Diagnosis:
        actions = safe_action_descriptions()
        action_context = {
            name: {
                "risk": str(rule.get("risk")),
                "description": str(rule.get("description", "")),
            }
            for name, rule in actions.items()
        }
        system = (
            "You are an autonomous SRE incident diagnosis and remediation advisor. "
            "Use only the supplied evidence. Choose at most one recommended_action from "
            "the supplied remediation catalog. Never invent an action outside the catalog. "
            "Prefer the smallest reversible action that can plausibly restore service. "
            "Return strict JSON with probable_cause, confidence, evidence, affected_resources, "
            "rationale, recommended_action and recommended_parameters. If no safe action can "
            "be justified, set recommended_action to null."
        )
        user = json.dumps(
            {
                "evidence": evidence.model_dump(mode="json"),
                "remediation_catalog": action_context,
            },
            indent=2,
        )
        payload: dict[str, Any] = {
            "model": self.settings.ollama_model,
            "stream": False,
            "format": "json",
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
            "options": {"temperature": 0.1},
        }
        try:
            response = await self.client.post("/api/chat", json=payload)
            response.raise_for_status()
            content = response.json()["message"]["content"]
            data = json.loads(content)
            diagnosis = Diagnosis.model_validate(data)
            if diagnosis.recommended_action not in actions:
                diagnosis.recommended_action = None
                diagnosis.recommended_parameters = {}
            return diagnosis
        except Exception:
            return self._fallback_diagnosis(evidence)

    def _fallback_diagnosis(self, evidence: Evidence) -> Diagnosis:
        annotation_summary = evidence.annotations.get("summary", evidence.alert_name)
        targets = [
            x
            for x in [
                evidence.labels.get("deployment"),
                evidence.labels.get("statefulset"),
                evidence.labels.get("daemonset"),
                evidence.labels.get("pod"),
                evidence.labels.get("node"),
                evidence.annotations.get("sre.target_name"),
            ]
            if x
        ]
        haystack = " ".join(
            [
                evidence.alert_name,
                evidence.annotations.get("summary", ""),
                evidence.annotations.get("description", ""),
                *evidence.observations,
            ]
        ).lower()

        action: str | None = None
        parameters: dict[str, Any] = {}

        if evidence.labels.get("node") and any(
            token in haystack for token in ["unschedulable", "cordoned", "scheduling disabled"]
        ):
            action = "uncordon_node"
        elif evidence.labels.get("daemonset"):
            action = "restart_daemonset"
        elif evidence.labels.get("statefulset"):
            if any(token in haystack for token in ["capacity", "saturation", "load", "pressure"]):
                action = "scale_statefulset"
                parameters["replicas"] = 3
            else:
                action = "restart_statefulset"
        elif evidence.labels.get("pod") and any(
            token in haystack
            for token in ["crashloop", "crash loop", "not ready", "stuck", "unhealthy"]
        ):
            action = "replace_single_pod"
        elif evidence.labels.get("deployment") and any(
            token in haystack
            for token in ["bad release", "regression", "5xx", "error rate", "failed rollout"]
        ):
            action = "rollback_deployment"
        elif evidence.labels.get("deployment") and any(
            token in haystack
            for token in ["capacity", "saturation", "cpu", "memory pressure", "latency"]
        ):
            action = "scale_deployment_extended"
            parameters["replicas"] = 3
        elif evidence.labels.get("deployment"):
            action = "restart_deployment"

        return Diagnosis(
            probable_cause=annotation_summary,
            confidence=0.70,
            evidence=evidence.observations or [f"Firing alert: {evidence.alert_name}"],
            affected_resources=targets,
            rationale=(
                "Deterministic fallback diagnosis and bounded remediation recommendation "
                "because the local LLM was unavailable or exceeded its response deadline."
            ),
            recommended_action=action,
            recommended_parameters=parameters,
        )

    async def close(self) -> None:
        await self.client.aclose()
