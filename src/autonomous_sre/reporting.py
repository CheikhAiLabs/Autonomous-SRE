from typing import Any
from uuid import UUID

from sqlalchemy import select

from autonomous_sre.database import AgentActivityRow, SessionLocal


async def list_incident_activity(
    incident_id: UUID,
    limit: int = 500,
) -> list[dict[str, Any]]:
    """Return an incident-local timeline without global activity truncation."""
    async with SessionLocal() as session:
        result = await session.execute(
            select(AgentActivityRow)
            .where(AgentActivityRow.incident_id == incident_id)
            .order_by(AgentActivityRow.created_at.asc())
            .limit(limit)
        )
        return [
            {
                "id": str(row.id),
                "agent_name": row.agent_name,
                "status": row.status,
                "message": row.message,
                "incident_id": str(row.incident_id) if row.incident_id else None,
                "details": row.details,
                "created_at": row.created_at.isoformat(),
            }
            for row in result.scalars().all()
        ]
