from datetime import UTC, datetime
from uuid import UUID

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

from autonomous_sre.database import get_incident, init_db, list_incidents, save_incident
from autonomous_sre.events import connect_nats, publish
from autonomous_sre.models import IncidentStatus
from autonomous_sre.tokens import verify_approval_token

app = FastAPI(title="Autonomous-SRE API", version="0.1.0")
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


@app.get("/api/v1/incidents")
async def incidents() -> list[dict[str, object]]:
    return [i.model_dump(mode="json") for i in await list_incidents()]


@app.get("/api/v1/incidents/{incident_id}")
async def incident(incident_id: UUID) -> dict[str, object]:
    item = await get_incident(incident_id)
    if item is None:
        raise HTTPException(404, "incident not found")
    return item.model_dump(mode="json")


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
