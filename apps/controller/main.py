import asyncio
from uuid import UUID

from autonomous_sre.config import get_settings
from autonomous_sre.database import init_db, record_agent_activity
from autonomous_sre.events import connect_nats, publish, subscribe_json
from autonomous_sre.kube_actions import KubernetesExecutor
from autonomous_sre.models import RemediationPlan, RemediationResult
from autonomous_sre.policy import PolicyClient
from autonomous_sre.prometheus import PrometheusClient


async def verify_recovery(
    plan: RemediationPlan,
    executor: KubernetesExecutor,
) -> tuple[bool, dict[str, object]]:
    settings = get_settings()
    deadline = asyncio.get_running_loop().time() + settings.recovery_verify_seconds

    if plan.verification_query and plan.verification_threshold is not None:
        prom = PrometheusClient()
        last_value: float | None = None
        try:
            while asyncio.get_running_loop().time() < deadline:
                last_value = await prom.query(plan.verification_query)
                if last_value is not None and last_value <= plan.verification_threshold:
                    return True, {
                        "verification": "prometheus-threshold",
                        "verification_query": plan.verification_query,
                        "observed_value": last_value,
                        "threshold": plan.verification_threshold,
                    }
                await asyncio.sleep(5)
        finally:
            await prom.close()

        return False, {
            "verification": "prometheus-threshold",
            "verification_query": plan.verification_query,
            "observed_value": last_value,
            "threshold": plan.verification_threshold,
        }

    last_details: dict[str, object] = {}
    while asyncio.get_running_loop().time() < deadline:
        verified, details = await executor.verify(plan)
        last_details = details
        if verified:
            return True, details
        await asyncio.sleep(5)

    return False, last_details or {
        "verification": "kubernetes-state",
        "reason": "verification timed out",
    }


async def main() -> None:
    await init_db()
    nc = await connect_nats()
    await record_agent_activity(
        "remediation-controller",
        "watching",
        "Waiting for approved remediation requests",
    )
    await record_agent_activity(
        "recovery-verifier",
        "idle",
        "Waiting for a remediation to verify",
    )
    executor = KubernetesExecutor()
    policy = PolicyClient()

    async def handle(payload: dict[str, object]) -> None:
        incident_id = UUID(str(payload["incident_id"]))
        plan = RemediationPlan.model_validate(payload["plan"])
        mode = str(payload.get("mode", "autonomous-low-risk"))
        decision = await policy.decide(plan)
        allowed = decision.result.value == "allow" or mode == "approved"

        if not allowed:
            await record_agent_activity(
                "remediation-controller",
                "blocked",
                "Controller refused the remediation policy decision",
                incident_id,
                {"reason": decision.reason},
            )
            result = RemediationResult(
                incident_id=incident_id,
                success=False,
                message=f"Execution refused by controller policy: {decision.reason}",
            )
        else:
            try:
                await record_agent_activity(
                    "remediation-controller",
                    "working",
                    f"Executing {plan.action} on {plan.namespace}/{plan.target_name}",
                    incident_id,
                )
                details = await executor.execute(plan)
                await record_agent_activity(
                    "remediation-controller",
                    "success",
                    f"Executed {plan.action}",
                    incident_id,
                    details,
                )
                await record_agent_activity(
                    "recovery-verifier",
                    "working",
                    "Verifying the post-remediation service and Kubernetes state",
                    incident_id,
                )
                verified, verification = await verify_recovery(plan, executor)
                await record_agent_activity(
                    "recovery-verifier",
                    "success" if verified else "error",
                    "Recovery confirmed" if verified else "Recovery verification failed",
                    incident_id,
                    verification,
                )
                details["post_remediation"] = verification
                result = RemediationResult(
                    incident_id=incident_id,
                    success=verified,
                    message=(
                        f"Executed and verified {plan.action}"
                        if verified
                        else f"Executed {plan.action}, but recovery verification failed"
                    ),
                    details=details,
                )
            except Exception as exc:
                await record_agent_activity(
                    "remediation-controller",
                    "error",
                    f"Remediation failed: {exc}",
                    incident_id,
                )
                result = RemediationResult(
                    incident_id=incident_id,
                    success=False,
                    message=str(exc),
                )
        await publish(nc, "remediation.result", result.model_dump(mode="json"))

    await subscribe_json(nc, "remediation.requested", handle)
    while True:
        await asyncio.sleep(3600)


if __name__ == "__main__":
    asyncio.run(main())
