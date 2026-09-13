import json
from collections.abc import Awaitable, Callable

import nats
from nats.aio.client import Client as NATS
from nats.js.api import AckPolicy, ConsumerConfig, RetentionPolicy, StorageType
from nats.js.errors import APIError, NotFoundError

from autonomous_sre.config import get_settings

EVENT_STREAM = "AUTONOMOUS_SRE"
DURABLE_SUBJECTS = ("remediation.requested", "remediation.result")
EVENT_MAX_AGE_SECONDS = 7 * 24 * 60 * 60
EVENT_ACK_WAIT_SECONDS = 5 * 60
EVENT_MAX_DELIVER = 10


async def ensure_event_stream(nc: NATS) -> None:
    """Ensure the durable remediation work queue exists in JetStream."""
    js = nc.jetstream()
    try:
        info = await js.stream_info(EVENT_STREAM)
    except NotFoundError:
        try:
            await js.add_stream(
                name=EVENT_STREAM,
                subjects=list(DURABLE_SUBJECTS),
                retention=RetentionPolicy.WORK_QUEUE,
                storage=StorageType.FILE,
                max_age=EVENT_MAX_AGE_SECONDS,
            )
        except APIError:
            # Multiple services may race during startup. If another service created
            # the stream first, the second lookup succeeds; otherwise startup fails.
            await js.stream_info(EVENT_STREAM)
        return

    configured_subjects = set(info.config.subjects or [])
    if not set(DURABLE_SUBJECTS).issubset(configured_subjects):
        await js.update_stream(
            name=EVENT_STREAM,
            subjects=sorted(configured_subjects | set(DURABLE_SUBJECTS)),
            retention=RetentionPolicy.WORK_QUEUE,
            storage=StorageType.FILE,
            max_age=EVENT_MAX_AGE_SECONDS,
        )


async def connect_nats() -> NATS:
    settings = get_settings()
    nc = await nats.connect(settings.nats_url, name="autonomous-sre")
    await ensure_event_stream(nc)
    return nc


async def publish(nc: NATS, subject: str, payload: dict[str, object]) -> None:
    encoded = json.dumps(payload).encode()
    if subject in DURABLE_SUBJECTS:
        await nc.jetstream().publish(
            subject,
            encoded,
            stream=EVENT_STREAM,
            timeout=5,
        )
        return

    await nc.publish(subject, encoded)
    await nc.flush()


async def subscribe_json(
    nc: NATS,
    subject: str,
    handler: Callable[[dict[str, object]], Awaitable[None]],
    *,
    durable: str | None = None,
) -> None:
    async def wrapped(msg: object) -> None:
        try:
            data = json.loads(msg.data.decode())  # type: ignore[attr-defined]
            await handler(data)
        except Exception as exc:
            if subject in DURABLE_SUBJECTS:
                print(f"jetstream-handler-error subject={subject}: {exc}", flush=True)
                await msg.nak(delay=5)  # type: ignore[attr-defined]
                return
            raise

        if subject in DURABLE_SUBJECTS:
            await msg.ack()  # type: ignore[attr-defined]

    if subject in DURABLE_SUBJECTS:
        if not durable:
            raise ValueError(f"A durable consumer name is required for {subject}")
        config = ConsumerConfig(
            durable_name=durable,
            ack_policy=AckPolicy.EXPLICIT,
            ack_wait=EVENT_ACK_WAIT_SECONDS,
            max_deliver=EVENT_MAX_DELIVER,
            filter_subject=subject,
        )
        await nc.jetstream().subscribe(
            subject,
            queue=durable,
            durable=durable,
            stream=EVENT_STREAM,
            cb=wrapped,
            config=config,
            manual_ack=True,
        )
        return

    await nc.subscribe(subject, cb=wrapped)
