from datetime import UTC, datetime
from uuid import UUID

from autonomous_sre.database import get_incident, save_incident
from autonomous_sre.models import IncidentStatus, RemediationResult
from autonomous_sre.notifications import send_incident_email


async def handle_result(payload: dict[str, object]) -> None:
    result = RemediationResult.model_validate(payload)
    incident = await get_incident(UUID(str(result.incident_id)))
    if incident is None:
        return
    incident.remediation_result = result.model_dump(mode="json")
    incident.status = IncidentStatus.RECOVERED if result.success else IncidentStatus.FAILED
    incident.updated_at = datetime.now(UTC)
    await save_incident(incident)
    await send_incident_email(
        incident,
        "RECOVERED AUTOMATICALLY" if result.success else "REMEDIATION FAILED",
    )
