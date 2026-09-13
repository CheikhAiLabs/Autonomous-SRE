from datetime import UTC, datetime, timedelta
from types import SimpleNamespace
from unittest.mock import AsyncMock
from uuid import uuid4

import pytest

from apps.controller import main as controller_module
from autonomous_sre import engine as engine_module
from autonomous_sre import result_handler as result_handler_module
from autonomous_sre.events import EVENT_STREAM, publish, subscribe_json
from autonomous_sre.models import (
    Diagnosis,
    Evidence,
    Incident,
    IncidentStatus,
    PolicyDecision,
    PolicyResult,
    RemediationPlan,
    Risk,
)


def remediation_tuple() -> tuple[Diagnosis, RemediationPlan, PolicyDecision]:
    return (
        Diagnosis(probable_cause="replica floor breached", confidence=0.9),
        RemediationPlan(
            action="scale_deployment",
            risk=Risk.LOW,
            namespace="demo",
            target_kind="Deployment",
            target_name="demo-service",
            parameters={"replicas": 2},
        ),
        PolicyDecision(result=PolicyResult.ALLOW, reason="guarded low-risk action"),
    )


class FakeReasoning:
    async def run(self, evidence: Evidence, incident_id: object):
        del evidence, incident_id
        return remediation_tuple()


def make_engine() -> engine_module.IncidentEngine:
    engine = engine_module.IncidentEngine.__new__(engine_module.IncidentEngine)
    engine.settings = SimpleNamespace(
        recovery_verify_seconds=90,
        incident_cooldown_seconds=300,
        auto_remediation_mode="autonomous-low-risk",
    )
    engine.nc = object()
    engine.reasoning = FakeReasoning()
    return engine


@pytest.mark.asyncio
async def test_engine_blocks_dispatch_when_controller_heartbeat_is_stale(monkeypatch):
    saved: list[Incident] = []

    async def save(item: Incident) -> None:
        saved.append(item.model_copy(deep=True))

    monkeypatch.setattr(engine_module, "find_active_by_fingerprint", AsyncMock(return_value=None))
    monkeypatch.setattr(engine_module, "find_recent_by_fingerprint", AsyncMock(return_value=None))
    monkeypatch.setattr(engine_module, "save_incident", save)
    monkeypatch.setattr(engine_module, "record_agent_activity", AsyncMock())
    monkeypatch.setattr(engine_module, "send_incident_email", AsyncMock())
    monkeypatch.setattr(engine_module, "agent_status_is_fresh", AsyncMock(return_value=False))
    publish_mock = AsyncMock()
    monkeypatch.setattr(engine_module, "publish", publish_mock)

    await make_engine().process_alert(
        {
            "labels": {
                "alertname": "DemoServiceReplicaFloorBreached",
                "namespace": "demo",
                "deployment": "demo-service",
            },
            "annotations": {"summary": "replica floor breached"},
        }
    )

    assert saved[-1].status == IncidentStatus.BLOCKED
    publish_mock.assert_not_awaited()


@pytest.mark.asyncio
async def test_stale_remediation_is_closed_before_fresh_dispatch(monkeypatch):
    stale = Incident(
        fingerprint="stale",
        status=IncidentStatus.REMEDIATING,
        updated_at=datetime.now(UTC) - timedelta(minutes=10),
        evidence=Evidence(alert_name="DemoServiceReplicaFloorBreached"),
    )
    saved: list[Incident] = []

    async def save(item: Incident) -> None:
        saved.append(item.model_copy(deep=True))

    monkeypatch.setattr(
        engine_module,
        "find_active_by_fingerprint",
        AsyncMock(return_value=stale),
    )
    recent_mock = AsyncMock(return_value=None)
    monkeypatch.setattr(engine_module, "find_recent_by_fingerprint", recent_mock)
    monkeypatch.setattr(engine_module, "save_incident", save)
    monkeypatch.setattr(engine_module, "record_agent_activity", AsyncMock())
    email_mock = AsyncMock()
    monkeypatch.setattr(engine_module, "send_incident_email", email_mock)
    monkeypatch.setattr(engine_module, "agent_status_is_fresh", AsyncMock(return_value=True))
    publish_mock = AsyncMock()
    monkeypatch.setattr(engine_module, "publish", publish_mock)

    await make_engine().process_alert(
        {
            "labels": {
                "alertname": "DemoServiceReplicaFloorBreached",
                "namespace": "demo",
                "deployment": "demo-service",
            },
            "annotations": {"summary": "replica floor breached"},
        }
    )

    assert any(item.id == stale.id and item.status == IncidentStatus.FAILED for item in saved)
    assert saved[-1].id != stale.id
    assert saved[-1].status == IncidentStatus.REMEDIATING
    recent_mock.assert_not_awaited()
    publish_mock.assert_awaited_once()
    assert email_mock.await_args.args[1] == "STALE REMEDIATION CLOSED"


@pytest.mark.asyncio
async def test_result_handler_closes_incident_and_sends_final_report(monkeypatch):
    incident = Incident(
        fingerprint="result",
        status=IncidentStatus.REMEDIATING,
        evidence=Evidence(alert_name="DemoServiceReplicaFloorBreached"),
    )
    monkeypatch.setattr(
        result_handler_module,
        "get_incident",
        AsyncMock(return_value=incident),
    )
    save_mock = AsyncMock()
    monkeypatch.setattr(result_handler_module, "save_incident", save_mock)
    monkeypatch.setattr(result_handler_module, "record_agent_activity", AsyncMock())
    email_mock = AsyncMock()
    monkeypatch.setattr(result_handler_module, "send_incident_email", email_mock)
    monkeypatch.setattr(result_handler_module, "_reset_pipeline_status", AsyncMock())

    await result_handler_module.handle_result(
        {
            "incident_id": str(incident.id),
            "success": True,
            "message": "recovered",
            "details": {"verification": "kubernetes-state"},
        }
    )

    assert incident.status == IncidentStatus.RECOVERED
    save_mock.assert_awaited_once()
    assert email_mock.await_args.args[1] == "RECOVERED AUTOMATICALLY"


@pytest.mark.asyncio
async def test_controller_verifier_accepts_confirmed_kubernetes_state(monkeypatch):
    monkeypatch.setattr(
        controller_module,
        "get_settings",
        lambda: SimpleNamespace(recovery_verify_seconds=5),
    )

    class Executor:
        async def verify(self, plan: RemediationPlan):
            del plan
            return True, {"verification": "kubernetes-state", "ready": True}

    plan = remediation_tuple()[1]
    verified, details = await controller_module.verify_recovery(plan, Executor())

    assert verified is True
    assert details["ready"] is True


class FakeMessage:
    def __init__(self, data: bytes) -> None:
        self.data = data
        self.acked = False
        self.nacked = False
        self.nak_delay: int | None = None

    async def ack(self) -> None:
        self.acked = True

    async def nak(self, delay: int = 0) -> None:
        self.nacked = True
        self.nak_delay = delay


class FakeJetStream:
    def __init__(self) -> None:
        self.published: list[tuple[str, bytes, str | None]] = []
        self.callback = None
        self.subscription_kwargs: dict[str, object] = {}

    async def publish(
        self,
        subject: str,
        payload: bytes,
        stream: str | None = None,
        timeout: int | None = None,
    ) -> None:
        del timeout
        self.published.append((subject, payload, stream))

    async def subscribe(self, subject: str, **kwargs: object) -> None:
        del subject
        self.callback = kwargs["cb"]
        self.subscription_kwargs = kwargs


class FakeNats:
    def __init__(self) -> None:
        self.js = FakeJetStream()

    def jetstream(self) -> FakeJetStream:
        return self.js


@pytest.mark.asyncio
async def test_remediation_events_publish_to_jetstream():
    nc = FakeNats()
    await publish(nc, "remediation.requested", {"incident_id": str(uuid4())})  # type: ignore[arg-type]

    assert nc.js.published[0][0] == "remediation.requested"
    assert nc.js.published[0][2] == EVENT_STREAM


@pytest.mark.asyncio
async def test_durable_consumer_acks_success_and_naks_failure():
    nc = FakeNats()
    handler = AsyncMock()
    await subscribe_json(  # type: ignore[arg-type]
        nc,
        "remediation.result",
        handler,
        durable="incident-result-handler-test",
    )
    callback = nc.js.callback
    assert callback is not None

    success = FakeMessage(b'{"incident_id":"ok"}')
    await callback(success)
    assert success.acked is True
    assert success.nacked is False

    handler.side_effect = RuntimeError("boom")
    failed = FakeMessage(b'{"incident_id":"retry"}')
    await callback(failed)
    assert failed.acked is False
    assert failed.nacked is True
    assert failed.nak_delay == 5
