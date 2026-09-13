from __future__ import annotations

import asyncio
import hashlib
import json
from datetime import UTC, datetime

from nats.aio.client import Client as NATS

from autonomous_sre.config import get_settings
from autonomous_sre.database import (
    agent_status_is_fresh,
    find_active_by_fingerprint,
    find_recent_by_fingerprint,
    record_agent_activity,
    save_incident,
)
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
            for key in ["alertname", "namespace", "pod", "deployment", "service", "node"]
        }
        return hashlib.sha256(json.dumps(stable, sort_keys=True).encode()).hexdigest()[:32]

    async def process_alert(self, alert: dict[str, object]) -> None:
        fp = self.fingerprint(alert)
        stale_recovered = False
        active = await find_active_by_fingerprint(fp)
        if active:
            stale_after = max(180, self.settings.recovery_verify_seconds + 90)
            age_seconds = (datetime.now(UTC) - active.updated_at).total_seconds()
            if active.status == IncidentStatus.REMEDIATING and age_seconds > stale_after:
                active.status = IncidentStatus.FAILED
                active.updated_at = datetime.now(UTC)
                active.remediation_result = {
                    "success": False,
                    "message": "Remediation timed out without a controller result",
                    "details": {
                        "reason": "stale-remediation-timeout",
                        "age_seconds": int(age_seconds),
                    },
                }
                await save_incident(active)
                await record_agent_activity(
                    "case-manager",
                    "error",
                    "Stale remediation closed after no controller result was received",
                    active.id,
                    {"age_seconds": int(age_seconds)},
                )
                await send_incident_email(active, "STALE REMEDIATION CLOSED")
                stale_recovered = True
            else:
                return

        if not stale_recovered and await find_recent_by_fingerprint(
            fp, self.settings.incident_cooldown_seconds
        ):
            return

        labels = {
            str(k): str(v)
            for k, v in (alert.get("labels") or {}).items()  # type: ignore[union-attr]
        }
        annotations = {
            str(k): str(v)
            for k, v in (alert.get("annotations") or {}).items()  # type: ignore[union-attr]
        }
        observation = annotations.get(
            "description",
            annotations.get("summary", "Firing alert"),
        )
        evidence = Evidence(
            alert_name=labels.get("alertname", "unknown"),
            labels=labels,
            annotations=annotations,
            observations=[observation],
        )
        incident = Incident(fingerprint=fp, evidence=evidence)
        await save_incident(incident)
        await record_agent_activity(
            "detector",
            "success",
            f"Detected managed alert {evidence.alert_name}",
            incident.id,
            {"fingerprint": incident.fingerprint, "severity": labels.get("severity", "unknown")},
        )
        await record_agent_activity(
            "case-manager",
            "working",
            "Incident opened and evidence collection started",
            incident.id,
        )

        diagnosis, plan, decision = await self.reasoning.run(evidence, incident.id)
        incident.diagnosis = diagnosis
        incident.plan = plan
        incident.status = IncidentStatus.DIAGNOSED
        incident.updated_at = datetime.now(UTC)

        if plan is None or decision is None:
            incident.status = IncidentStatus.BLOCKED
            await save_incident(incident)
            await record_agent_activity(
                "case-manager",
                "blocked",
                "Incident requires manual investigation because no safe remediation was available",
                incident.id,
            )
            await send_incident_email(incident, "MANUAL INVESTIGATION REQUIRED")
            return

        incident.policy = decision
        incident.updated_at = datetime.now(UTC)

        if decision.result == PolicyResult.ALLOW:
            if not await agent_status_is_fresh("remediation-controller", max_age_seconds=45):
                incident.status = IncidentStatus.BLOCKED
                incident.updated_at = datetime.now(UTC)
                await save_incident(incident)
                await record_agent_activity(
                    "case-manager",
                    "blocked",
                    (
                        "Autonomous remediation was not dispatched because "
                        "the controller heartbeat is stale"
                    ),
                    incident.id,
                    {"action": plan.action, "reason": "remediation-controller-unhealthy"},
                )
                await send_incident_email(incident, "REMEDIATION CONTROLLER UNAVAILABLE")
                return

            incident.status = IncidentStatus.REMEDIATING
            await save_incident(incident)
            await record_agent_activity(
                "case-manager",
                "working",
                f"Autonomous remediation authorised: {plan.action}",
                incident.id,
            )
            try:
                await publish(
                    self.nc,
                    "remediation.requested",
                    {
                        "incident_id": str(incident.id),
                        "plan": plan.model_dump(mode="json"),
                        "mode": self.settings.auto_remediation_mode,
                    },
                )
                await record_agent_activity(
                    "case-manager",
                    "success",
                    f"Remediation request dispatched to controller: {plan.action}",
                    incident.id,
                )
            except Exception as exc:
                incident.status = IncidentStatus.FAILED
                incident.updated_at = datetime.now(UTC)
                await save_incident(incident)
                await record_agent_activity(
                    "case-manager",
                    "error",
                    "Failed to dispatch remediation request",
                    incident.id,
                    {"error": str(exc), "action": plan.action},
                )
                await send_incident_email(incident, "REMEDIATION DISPATCH FAILED")
        elif decision.result == PolicyResult.REQUIRE_APPROVAL:
            incident.status = IncidentStatus.PENDING_APPROVAL
            await save_incident(incident)
            await record_agent_activity(
                "case-manager",
                "waiting",
                f"Human approval required before {plan.action}",
                incident.id,
            )
            await send_incident_email(incident, "APPROVAL REQUIRED")
        else:
            incident.status = IncidentStatus.BLOCKED
            await save_incident(incident)
            await record_agent_activity(
                "case-manager",
                "blocked",
                f"Policy blocked remediation {plan.action}",
                incident.id,
                {"reason": decision.reason},
            )
            await send_incident_email(incident, "ACTION BLOCKED BY POLICY")

    async def run(self) -> None:
        await record_agent_activity(
            "detector",
            "watching",
            "Watching Prometheus for managed alerts",
        )
        while True:
            try:
                for alert in await self.prom.firing_alerts():
                    labels = alert.get("labels") or {}
                    managed = str(labels.get("sre_managed", "false")).lower()  # type: ignore[union-attr]
                    if managed == "true":
                        await self.process_alert(alert)
            except Exception as exc:
                await record_agent_activity(
                    "detector",
                    "error",
                    "Prometheus incident loop failed",
                    details={"error": str(exc)},
                )
                print(f"incident-loop-error: {exc}", flush=True)
            await asyncio.sleep(self.settings.incident_poll_interval_seconds)
