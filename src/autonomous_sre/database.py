from __future__ import annotations

from datetime import UTC, datetime, timedelta
from typing import Any
from uuid import UUID

from sqlalchemy import JSON, DateTime, String, Text, select
from sqlalchemy.dialects.postgresql import UUID as PGUUID
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column

from autonomous_sre.config import get_settings
from autonomous_sre.models import Incident, IncidentStatus


class Base(DeclarativeBase):
    pass


class IncidentRow(Base):
    __tablename__ = "incidents"

    id: Mapped[UUID] = mapped_column(PGUUID(as_uuid=True), primary_key=True)
    fingerprint: Mapped[str] = mapped_column(String(255), index=True)
    status: Mapped[str] = mapped_column(String(64), index=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    evidence: Mapped[dict[str, Any]] = mapped_column(JSON)
    diagnosis: Mapped[dict[str, Any] | None] = mapped_column(JSON, nullable=True)
    plan: Mapped[dict[str, Any] | None] = mapped_column(JSON, nullable=True)
    policy: Mapped[dict[str, Any] | None] = mapped_column(JSON, nullable=True)
    remediation_result: Mapped[dict[str, Any] | None] = mapped_column(JSON, nullable=True)
    notes: Mapped[str | None] = mapped_column(Text, nullable=True)

    def to_model(self) -> Incident:
        return Incident.model_validate(
            {
                "id": self.id,
                "fingerprint": self.fingerprint,
                "status": self.status,
                "created_at": self.created_at,
                "updated_at": self.updated_at,
                "evidence": self.evidence,
                "diagnosis": self.diagnosis,
                "plan": self.plan,
                "policy": self.policy,
                "remediation_result": self.remediation_result,
            }
        )


settings = get_settings()
engine = create_async_engine(settings.database_url, pool_pre_ping=True)
SessionLocal = async_sessionmaker(engine, expire_on_commit=False)


async def init_db() -> None:
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)


async def save_incident(incident: Incident) -> None:
    payload = incident.model_dump(mode="json")
    async with SessionLocal() as session:
        row = await session.get(IncidentRow, incident.id)
        if row is None:
            row = IncidentRow(
                id=incident.id,
                fingerprint=incident.fingerprint,
                status=incident.status.value,
                created_at=incident.created_at,
                updated_at=incident.updated_at,
                evidence=payload["evidence"],
                diagnosis=payload["diagnosis"],
                plan=payload["plan"],
                policy=payload["policy"],
                remediation_result=payload["remediation_result"],
            )
            session.add(row)
        else:
            row.status = incident.status.value
            row.updated_at = incident.updated_at
            row.evidence = payload["evidence"]
            row.diagnosis = payload["diagnosis"]
            row.plan = payload["plan"]
            row.policy = payload["policy"]
            row.remediation_result = payload["remediation_result"]
        await session.commit()


async def list_incidents(limit: int = 100) -> list[Incident]:
    async with SessionLocal() as session:
        result = await session.execute(
            select(IncidentRow).order_by(IncidentRow.created_at.desc()).limit(limit)
        )
        return [row.to_model() for row in result.scalars().all()]


async def get_incident(incident_id: UUID) -> Incident | None:
    async with SessionLocal() as session:
        row = await session.get(IncidentRow, incident_id)
        return row.to_model() if row else None


async def find_active_by_fingerprint(fingerprint: str) -> Incident | None:
    active = {
        IncidentStatus.OPEN.value,
        IncidentStatus.DIAGNOSED.value,
        IncidentStatus.PENDING_APPROVAL.value,
        IncidentStatus.REMEDIATING.value,
    }
    async with SessionLocal() as session:
        result = await session.execute(
            select(IncidentRow)
            .where(IncidentRow.fingerprint == fingerprint, IncidentRow.status.in_(active))
            .order_by(IncidentRow.created_at.desc())
            .limit(1)
        )
        row = result.scalar_one_or_none()
        return row.to_model() if row else None


async def find_recent_by_fingerprint(fingerprint: str, cooldown_seconds: int) -> Incident | None:
    cutoff = datetime.now(UTC) - timedelta(seconds=cooldown_seconds)
    async with SessionLocal() as session:
        result = await session.execute(
            select(IncidentRow)
            .where(IncidentRow.fingerprint == fingerprint, IncidentRow.updated_at >= cutoff)
            .order_by(IncidentRow.updated_at.desc())
            .limit(1)
        )
        row = result.scalar_one_or_none()
        return row.to_model() if row else None
