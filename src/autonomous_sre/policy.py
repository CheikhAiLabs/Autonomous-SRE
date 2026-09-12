import httpx

from autonomous_sre.config import get_settings
from autonomous_sre.models import PolicyDecision, RemediationPlan


class PolicyClient:
    def __init__(self) -> None:
        self.settings = get_settings()
        self.client = httpx.AsyncClient(base_url=self.settings.opa_url, timeout=10.0)

    async def decide(self, plan: RemediationPlan) -> PolicyDecision:
        payload = {
            "input": {
                "mode": self.settings.auto_remediation_mode,
                "action": plan.action,
                "risk": plan.risk.value,
                "namespace": plan.namespace,
                "target_kind": plan.target_kind,
                "target_name": plan.target_name,
                "blast_radius": plan.blast_radius,
                "parameters": plan.parameters,
            }
        }
        response = await self.client.post(
            "/v1/data/autonomous_sre/remediation/decision", json=payload
        )
        response.raise_for_status()
        result = response.json().get("result") or {
            "result": "deny",
            "reason": "OPA returned no decision",
        }
        return PolicyDecision.model_validate(result)

    async def close(self) -> None:
        await self.client.aclose()
