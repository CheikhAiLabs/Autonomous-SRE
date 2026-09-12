from __future__ import annotations

from typing import Any

import httpx

from autonomous_sre.config import get_settings


class PrometheusClient:
    def __init__(self) -> None:
        self.settings = get_settings()
        self.client = httpx.AsyncClient(base_url=self.settings.prometheus_url, timeout=15.0)

    async def firing_alerts(self) -> list[dict[str, Any]]:
        response = await self.client.get("/api/v1/alerts")
        response.raise_for_status()
        data = response.json()["data"]["alerts"]
        return [alert for alert in data if alert.get("state") == "firing"]

    async def query(self, promql: str) -> float | None:
        response = await self.client.get("/api/v1/query", params={"query": promql})
        response.raise_for_status()
        result = response.json()["data"]["result"]
        if not result:
            return None
        try:
            return float(result[0]["value"][1])
        except (KeyError, TypeError, ValueError):
            return None

    async def close(self) -> None:
        await self.client.aclose()
