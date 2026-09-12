from __future__ import annotations

from typing import TypedDict

from langgraph.graph import END, START, StateGraph

from autonomous_sre.llm import LocalReasoner
from autonomous_sre.models import Diagnosis, Evidence, PolicyDecision, RemediationPlan
from autonomous_sre.planner import build_plan
from autonomous_sre.policy import PolicyClient


class ReasoningState(TypedDict, total=False):
    evidence: Evidence
    diagnosis: Diagnosis
    plan: RemediationPlan | None
    policy: PolicyDecision | None


class ReasoningGraph:
    """Bounded agentic workflow.

    The local model may diagnose evidence, but it cannot execute tools. Planning is
    constrained to alert metadata, and OPA remains the final policy decision point.
    """

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
        return {"diagnosis": await self.reasoner.diagnose(state["evidence"])}

    def _plan(self, state: ReasoningState) -> dict[str, RemediationPlan | None]:
        return {"plan": build_plan(state["evidence"], state["diagnosis"])}

    async def _policy(self, state: ReasoningState) -> dict[str, PolicyDecision | None]:
        plan = state.get("plan")
        if plan is None:
            return {"policy": None}
        return {"policy": await self.policy.decide(plan)}

    async def run(
        self, evidence: Evidence
    ) -> tuple[Diagnosis, RemediationPlan | None, PolicyDecision | None]:
        result = await self.graph.ainvoke({"evidence": evidence})
        return result["diagnosis"], result.get("plan"), result.get("policy")
