from __future__ import annotations

from email.message import EmailMessage

import aiosmtplib

from autonomous_sre.config import get_settings
from autonomous_sre.models import Incident
from autonomous_sre.tokens import create_approval_token


async def send_incident_email(incident: Incident, subject_prefix: str) -> None:
    settings = get_settings()
    if not settings.smtp_password or not settings.smtp_username:
        return

    token = create_approval_token(incident.id)
    link = f"{settings.dashboard_base_url}/incidents/{incident.id}#token={token}"
    plan = incident.plan
    diagnosis = incident.diagnosis

    body = [
        f"Incident: {incident.id}",
        f"Status: {incident.status.value}",
        f"Root cause: {diagnosis.probable_cause if diagnosis else 'pending'}",
    ]
    if plan:
        body.extend(
            [
                f"Action: {plan.action}",
                f"Risk: {plan.risk.value}",
                f"Target: {plan.namespace}/{plan.target_name}",
            ]
        )
    if incident.status.value == "pending_approval":
        body.extend(["", "Review and approve/reject:", link])
    else:
        body.extend(["", "Dashboard:", settings.dashboard_base_url])

    msg = EmailMessage()
    msg["Subject"] = f"[Autonomous-SRE] {subject_prefix} {incident.id}"
    msg["From"] = settings.smtp_from or settings.smtp_username
    msg["To"] = settings.alert_email
    msg.set_content("\n".join(body))

    host, port_text = settings.smtp_smarthost.rsplit(":", 1)
    try:
        await aiosmtplib.send(
            msg,
            hostname=host,
            port=int(port_text),
            username=settings.smtp_username,
            password=settings.smtp_password,
            start_tls=True,
            timeout=20,
        )
    except Exception as exc:
        print(f"email-notification-error: {exc}", flush=True)
