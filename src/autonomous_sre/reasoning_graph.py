from __future__ import annotations

from typing import TypedDict
from uuid import UUID

from langgraph.graph import END, START, StateGraph

from autonomous_sre.database import record_agent_activity
from autonomous_sre.llm import LocalReasoner
from autonomous_sre.models import Diagnosis, Evidence, PolicyDecision, RemediationPlan
from autonomous_sre.planner import build_plan
from autonomous_sre.policy import PolicyClient


class ReasoningState(TypedDict, total=False):
    evidence: Evidence
    incident_id: UUID
    diagnosis: Diagnosis
    plan: RemediationPlan | None
    policy: PolicyDecision | None


class ReasoningGraph:
    """Bounded and observable agentic workflow."""

    def __init__(self, reasoner: LocalReasoner, policy: PolicyClient) -> None:
        self.reasoner = reasoner
        self.policy = policy

        graph = StateGraph(ReasoningState)
        graph.add_node("diagnose", self._diagnose)
        graph.add_node("plan", self._plan)
        graph.add_node("policy", self._policy)
        graph.add_edge(START, "diagnose")
        graph.add_edge("diagnose", "plan")
        graph.add_edge("plan", "policy")
        graph.add_edge("policy", END)
        self.graph = graph.compile()

    async def _diagnose(self, state: ReasoningState) -> dict[str, Diagnosis]:
        incident_id = state["incident_id"]
        await record_agent_activity(
            "ai-reasoner",
            "working",
            "Analysing incident evidence with the local model",
            incident_id,
        )
        diagnosis = await self.reasoner.diagnose(state["evidence"])
        await record_agent_activity(
            "ai-reasoner",
            "success",
            f"Diagnosis produced at {diagnosis.confidence:.0%} confidence",
            incident_id,
            {"probable_cause": diagnosis.probable_cause},
        )
        return {"diagnosis": diagnosis}

    async def _plan(self, state: ReasoningState) -> dict[str, RemediationPlan | None]:
        incident_id = state["incident_id"]
        await record_agent_activity(
            "planner",
            "working",
            "Building a bounded remediation proposal",
            incident_id,
        )
        plan = build_plan(state["evidence"], state["diagnosis"])
        await record_agent_activity(
            "planner",
            "success" if plan else "blocked",
            f"Proposed {plan.action}" if plan else "No safe action could be proposed",
            incident_id,
            plan.model_dump(mode="json") if plan else {},
        )
        return {"plan": plan}

    async def _policy(self, state: ReasoningState) -> dict[str, PolicyDecision | None]:
        incident_id = state["incident_id"]
        plan = state.get("plan")
        if plan is None:
            await record_agent_activity(
                "policy-guard",
                "blocked",
                "No remediation plan to evaluate",
                incident_id,
            )
            return {"policy": None}
        await record_agent_activity(
            "policy-guard",
            "working",
            "Evaluating risk and blast radius with OPA",
            incident_id,
        )
        decision = await self.policy.decide(plan)
        await record_agent_activity(
            "policy-guard",
            "success" if decision.result.value == "allow" else decision.result.value,
            f"OPA decision: {decision.result.value}",
            incident_id,
            {"reason": decision.reason},
        )
        return {"policy": decision}

    async def run(
        self, evidence: Evidence, incident_id: UUID
    ) -> tuple[Diagnosis, RemediationPlan | None, PolicyDecision | None]:
        result = await self.graph.ainvoke(
            {"evidence": evidence, "incident_id": incident_id}
        )
        return result["diagnosis"], result.get("plan"), result.get("policy")
