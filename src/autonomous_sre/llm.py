from __future__ import annotations

import json
from typing import Any

import httpx

from autonomous_sre.config import get_settings
from autonomous_sre.models import Diagnosis, Evidence


class LocalReasoner:
    def __init__(self) -> None:
        self.settings = get_settings()
        self.client = httpx.AsyncClient(base_url=self.settings.ollama_url, timeout=90.0)

    async def diagnose(self, evidence: Evidence) -> Diagnosis:
        system = (
            "You are an SRE incident diagnosis engine. Use only the supplied evidence. "
            "Do not invent commands. Return strict JSON with probable_cause, confidence, "
            "evidence, affected_resources and rationale."
        )
        user = json.dumps(evidence.model_dump(mode="json"), indent=2)
        payload: dict[str, Any] = {
            "model": self.settings.ollama_model,
            "stream": False,
            "format": "json",
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
            "options": {"temperature": 0.1},
        }
        try:
            response = await self.client.post("/api/chat", json=payload)
            response.raise_for_status()
            content = response.json()["message"]["content"]
            data = json.loads(content)
            return Diagnosis.model_validate(data)
        except Exception:
            # Deterministic fallback keeps remediation available if the local model is warming up.
            annotation_summary = evidence.annotations.get("summary", evidence.alert_name)
            targets = [
                x
                for x in [
                    evidence.labels.get("deployment"),
                    evidence.labels.get("pod"),
                    evidence.annotations.get("sre.target_name"),
                ]
                if x
            ]
            return Diagnosis(
                probable_cause=annotation_summary,
                confidence=0.70,
                evidence=evidence.observations or [f"Firing alert: {evidence.alert_name}"],
                affected_resources=targets,
                rationale="Deterministic fallback diagnosis because local LLM was unavailable.",
            )

    async def close(self) -> None:
        await self.client.aclose()
