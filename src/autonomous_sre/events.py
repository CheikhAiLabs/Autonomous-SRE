import json
from collections.abc import Awaitable, Callable

import nats
from nats.aio.client import Client as NATS

from autonomous_sre.config import get_settings


async def connect_nats() -> NATS:
    settings = get_settings()
    return await nats.connect(settings.nats_url, name="autonomous-sre")


async def publish(nc: NATS, subject: str, payload: dict[str, object]) -> None:
    await nc.publish(subject, json.dumps(payload).encode())
    await nc.flush()


async def subscribe_json(
    nc: NATS,
    subject: str,
    handler: Callable[[dict[str, object]], Awaitable[None]],
) -> None:
    async def wrapped(msg: object) -> None:
        data = json.loads(msg.data.decode())  # type: ignore[attr-defined]
        await handler(data)

    await nc.subscribe(subject, cb=wrapped)
