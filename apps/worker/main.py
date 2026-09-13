import asyncio

from autonomous_sre.database import init_db
from autonomous_sre.engine import IncidentEngine
from autonomous_sre.events import connect_nats, subscribe_json
from autonomous_sre.result_handler import handle_result


async def main() -> None:
    await init_db()
    nc = await connect_nats()
    await subscribe_json(
        nc,
        "remediation.result",
        handle_result,
        durable="incident-result-handler",
    )
    engine = IncidentEngine(nc)
    await engine.run()


if __name__ == "__main__":
    asyncio.run(main())
