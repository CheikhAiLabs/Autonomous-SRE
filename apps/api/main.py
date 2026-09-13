from datetime import UTC, datetime
from uuid import UUID

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

from autonomous_sre.config import get_settings
from autonomous_sre.database import (
    get_incident,
    init_db,
    list_agent_activity,
    list_agent_statuses,
    list_incidents,
    save_incident,
)
from autonomous_sre.events import connect_nats, publish
from autonomous_sre.models import IncidentStatus
from autonomous_sre.reporting import list_incident_activity
from autonomous_sre.tokens import verify_approval_token

app = FastAPI(title="Autonomous-SRE API", version="0.4.0")
nc = None


class ApprovalRequest(BaseModel):
    token: str


@app.on_event("startup")
async def startup() -> None:
    global nc
    await init_db()
    nc = await connect_nats()


@app.on_event("shutdown")
async def shutdown() -> None:
    if nc:
        await nc.close()


@app.get("/healthz")
async def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/api/v1/system")
async def system() -> dict[str, object]:
    settings = get_settings()
    mail_enabled = bool(
        settings.smtp_username and settings.smtp_password and settings.alert_email
    )
    return {
        "environment": settings.environment,
        "mode": settings.auto_remediation_mode,
        "poll_interval_seconds": settings.incident_poll_interval_seconds,
        "mail_enabled": mail_enabled,
        "report_recipient": settings.alert_email if settings.alert_email else None,
        "event_delivery": "jetstream-durable",
    }


@app.get("/api/v1/agents")
async def agents() -> list[dict[str, object]]:
    return await list_agent_statuses()


@app.get("/api/v1/activity")
async def activity() -> list[dict[str, object]]:
    return await list_agent_activity()


@app.get("/api/v1/incidents")
async def incidents() -> list[dict[str, object]]:
    return [i.model_dump(mode="json") for i in await list_incidents()]


@app.get("/api/v1/incidents/{incident_id}")
async def incident(incident_id: UUID) -> dict[str, object]:
    item = await get_incident(incident_id)
    if item is None:
        raise HTTPException(404, "incident not found")
    return item.model_dump(mode="json")


@app.get("/api/v1/incidents/{incident_id}/report")
async def incident_report(incident_id: UUID) -> dict[str, object]:
    item = await get_incident(incident_id)
    if item is None:
        raise HTTPException(404, "incident not found")

    incident_activity = await list_incident_activity(item.id)
    notification_events = [
        event for event in incident_activity if event.get("agent_name") == "notification"
    ]
    latest_notification = notification_events[-1] if notification_events else None

    payload = item.model_dump(mode="json")
    started = item.created_at
    finished = item.updated_at
    duration_seconds = max(0, int((finished - started).total_seconds()))

    email_delivery = {
        "status": "not_attempted",
        "message": "No incident email has been attempted",
        "recipient": None,
        "updated_at": None,
    }
    if latest_notification:
        details = latest_notification.get("details") or {}
        email_delivery = {
            "status": latest_notification.get("status", "unknown"),
            "message": latest_notification.get("message"),
            "recipient": details.get("recipient") if isinstance(details, dict) else None,
            "updated_at": latest_notification.get("created_at"),
        }

    return {
        "report_type": "autonomous-sre-intervention",
        "generated_at": datetime.now(UTC).isoformat(),
        "incident_id": str(item.id),
        "status": item.status.value,
        "started_at": started.isoformat(),
        "finished_at": finished.isoformat(),
        "duration_seconds": duration_seconds,
        "alert": payload.get("evidence", {}),
        "diagnosis": payload.get("diagnosis"),
        "plan": payload.get("plan"),
        "policy": payload.get("policy"),
        "remediation_result": payload.get("remediation_result"),
        "email_delivery": email_delivery,
        "timeline": incident_activity,
    }


@app.post("/api/v1/incidents/{incident_id}/approve")
async def approve(incident_id: UUID, req: ApprovalRequest) -> dict[str, str]:
    item = await get_incident(incident_id)
    if item is None:
        raise HTTPException(404, "incident not found")
    if item.status != IncidentStatus.PENDING_APPROVAL or item.plan is None:
        raise HTTPException(409, "incident is not awaiting approval")
    if not verify_approval_token(req.token, incident_id):
        raise HTTPException(403, "invalid or expired approval token")
    item.status = IncidentStatus.REMEDIATING
    item.updated_at = datetime.now(UTC)
    await save_incident(item)
    await publish(
        nc,
        "remediation.requested",
        {
            "incident_id": str(item.id),
            "plan": item.plan.model_dump(mode="json"),
            "mode": "approved",
            "approval_token": req.token,
        },
    )
    return {"status": "approved"}


@app.post("/api/v1/incidents/{incident_id}/reject")
async def reject(incident_id: UUID, req: ApprovalRequest) -> dict[str, str]:
    item = await get_incident(incident_id)
    if item is None:
        raise HTTPException(404, "incident not found")
    if item.status != IncidentStatus.PENDING_APPROVAL:
        raise HTTPException(409, "incident is not awaiting approval")
    if not verify_approval_token(req.token, incident_id):
        raise HTTPException(403, "invalid or expired approval token")
    item.status = IncidentStatus.REJECTED
    item.updated_at = datetime.now(UTC)
    await save_incident(item)
    return {"status": "rejected"}
