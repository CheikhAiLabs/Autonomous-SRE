from __future__ import annotations

import asyncio
import hashlib
import json
from datetime import datetime, timezone

from nats.aio.client import Client as NATS

from autonomous_sre.config import get_settings
from autonomous_sre.database import find_active_by_fingerprint, find_recent_by_fingerprint, save_incident
from autonomous_sre.events import publish
from autonomous_sre.llm import LocalReasoner
from autonomous_sre.models import Evidence, Incident, IncidentStatus, PolicyResult
from autonomous_sre.notifications import send_incident_email
from autonomous_sre.policy import PolicyClient
from autonomous_sre.prometheus import PrometheusClient
from autonomous_sre.reasoning_graph import ReasoningGraph


class IncidentEngine:
    def __init__(self, nc: NATS) -> None:
        self.settings = get_settings()
        self.nc = nc
        self.prom = PrometheusClient()
        self.reasoner = LocalReasoner()
        self.policy = PolicyClient()
        self.reasoning = ReasoningGraph(self.reasoner, self.policy)

    @staticmethod
    def fingerprint(alert: dict[str, object]) -> str:
        labels = alert.get("labels") or {}
        stable = {
            key: labels.get(key)  # type: ignore[union-attr]
            for key in ["alertname", "namespace", "pod", "deployment", "service"]
        }
        return hashlib.sha256(json.dumps(stable, sort_keys=True).encode()).hexdigest()[:32]

    async def process_alert(self, alert: dict[str, object]) -> None:
        fp = self.fingerprint(alert)
        if await find_active_by_fingerprint(fp):
            return
        if await find_recent_by_fingerprint(fp, self.settings.incident_cooldown_seconds):
            return

        labels = {str(k): str(v) for k, v in (alert.get("labels") or {}).items()}  # type: ignore[union-attr]
        annotations = {
            str(k): str(v) for k, v in (alert.get("annotations") or {}).items()  # type: ignore[union-attr]
        }
        evidence = Evidence(
            alert_name=labels.get("alertname", "unknown"),
            labels=labels,
            annotations=annotations,
            observations=[annotations.get("description", annotations.get("summary", "Firing alert"))],
        )
        incident = Incident(fingerprint=fp, evidence=evidence)
        await save_incident(incident)
        await send_incident_email(incident, "INCIDENT DETECTED")

        diagnosis, plan, decision = await self.reasoning.run(evidence)
        incident.diagnosis = diagnosis
        incident.plan = plan
        incident.status = IncidentStatus.DIAGNOSED
        incident.updated_at = datetime.now(timezone.utc)

        if plan is None or decision is None:
            incident.status = IncidentStatus.BLOCKED
            await save_incident(incident)
            await send_incident_email(incident, "MANUAL INVESTIGATION REQUIRED")
            return

        incident.policy = decision
        incident.updated_at = datetime.now(timezone.utc)

        if decision.result == PolicyResult.ALLOW:
            incident.status = IncidentStatus.REMEDIATING
            await save_incident(incident)
            await publish(
                self.nc,
                "remediation.requested",
                {
                    "incident_id": str(incident.id),
                    "plan": plan.model_dump(mode="json"),
                    "mode": self.settings.auto_remediation_mode,
                },
            )
            await send_incident_email(incident, "AUTONOMOUS REMEDIATION STARTED")
        elif decision.result == PolicyResult.REQUIRE_APPROVAL:
            incident.status = IncidentStatus.PENDING_APPROVAL
            await save_incident(incident)
            await send_incident_email(incident, "APPROVAL REQUIRED")
        else:
            incident.status = IncidentStatus.BLOCKED
            await save_incident(incident)
            await send_incident_email(incident, "ACTION BLOCKED BY POLICY")

    async def run(self) -> None:
        while True:
            try:
                for alert in await self.prom.firing_alerts():
                    labels = alert.get("labels") or {}
                    if str(labels.get("sre_managed", "false")).lower() == "true":  # type: ignore[union-attr]
                        await self.process_alert(alert)
            except Exception as exc:
                print(f"incident-loop-error: {exc}", flush=True)
            await asyncio.sleep(self.settings.incident_poll_interval_seconds)
