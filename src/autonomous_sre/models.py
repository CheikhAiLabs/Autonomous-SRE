from __future__ import annotations

from datetime import UTC, datetime
from enum import StrEnum
from typing import Any
from uuid import UUID, uuid4

from pydantic import BaseModel, Field


class Risk(StrEnum):
    LOW = "low"
    MEDIUM = "medium"
    HIGH = "high"
    FORBIDDEN = "forbidden"


class IncidentStatus(StrEnum):
    OPEN = "open"
    DIAGNOSED = "diagnosed"
    PENDING_APPROVAL = "pending_approval"
    REMEDIATING = "remediating"
    RECOVERED = "recovered"
    FAILED = "failed"
    REJECTED = "rejected"
    BLOCKED = "blocked"


class PolicyResult(StrEnum):
    ALLOW = "allow"
    REQUIRE_APPROVAL = "require_approval"
    DENY = "deny"


class Evidence(BaseModel):
    alert_name: str
    labels: dict[str, str] = Field(default_factory=dict)
    annotations: dict[str, str] = Field(default_factory=dict)
    metric_samples: dict[str, float] = Field(default_factory=dict)
    observations: list[str] = Field(default_factory=list)


class Diagnosis(BaseModel):
    probable_cause: str
    confidence: float = Field(ge=0.0, le=1.0)
    evidence: list[str] = Field(default_factory=list)
    affected_resources: list[str] = Field(default_factory=list)
    rationale: str = ""
    recommended_action: str | None = None
    recommended_parameters: dict[str, Any] = Field(default_factory=dict)


class RemediationPlan(BaseModel):
    action: str
    risk: Risk
    namespace: str
    target_kind: str
    target_name: str
    parameters: dict[str, Any] = Field(default_factory=dict)
    blast_radius: int = Field(default=1, ge=0)
    verification_query: str | None = None
    verification_threshold: float | None = None


class PolicyDecision(BaseModel):
    result: PolicyResult
    reason: str


class Incident(BaseModel):
    id: UUID = Field(default_factory=uuid4)
    fingerprint: str
    status: IncidentStatus = IncidentStatus.OPEN
    created_at: datetime = Field(default_factory=lambda: datetime.now(UTC))
    updated_at: datetime = Field(default_factory=lambda: datetime.now(UTC))
    evidence: Evidence
    diagnosis: Diagnosis | None = None
    plan: RemediationPlan | None = None
    policy: PolicyDecision | None = None
    remediation_result: dict[str, Any] | None = None


class RemediationRequest(BaseModel):
    incident_id: UUID
    plan: RemediationPlan
    mode: str


class RemediationResult(BaseModel):
    incident_id: UUID
    success: bool
    message: str
    details: dict[str, Any] = Field(default_factory=dict)
