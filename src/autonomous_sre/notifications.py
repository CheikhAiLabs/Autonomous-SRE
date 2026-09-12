from __future__ import annotations

from email.message import EmailMessage

import aiosmtplib

from autonomous_sre.config import get_settings
from autonomous_sre.models import Incident
from autonomous_sre.tokens import create_approval_token


def _format_duration(seconds: int) -> str:
    minutes, seconds = divmod(max(0, seconds), 60)
    hours, minutes = divmod(minutes, 60)
    if hours:
        return f"{hours}h {minutes}m {seconds}s"
    if minutes:
        return f"{minutes}m {seconds}s"
    return f"{seconds}s"


async def send_incident_email(incident: Incident, subject_prefix: str) -> None:
    settings = get_settings()
    if not settings.smtp_password or not settings.smtp_username or not settings.alert_email:
        return

    token = create_approval_token(incident.id)
    link = f"{settings.dashboard_base_url}/incidents/{incident.id}#token={token}"
    plan = incident.plan
    diagnosis = incident.diagnosis
    policy = incident.policy
    result = incident.remediation_result or {}
    duration = int((incident.updated_at - incident.created_at).total_seconds())

    body = [
        "AUTONOMOUS SRE - INTERVENTION REPORT",
        "",
        f"Incident ID: {incident.id}",
        f"Status: {incident.status.value}",
        f"Started: {incident.created_at.isoformat()}",
        f"Last update: {incident.updated_at.isoformat()}",
        f"Duration: {_format_duration(duration)}",
        "",
        "DIAGNOSIS",
        f"Root cause: {diagnosis.probable_cause if diagnosis else 'pending'}",
        f"Confidence: {round((diagnosis.confidence if diagnosis else 0) * 100)}%",
        "",
        "REMEDIATION",
    ]

    if plan:
        body.extend(
            [
                f"Action: {plan.action}",
                f"Risk: {plan.risk.value}",
                f"Target: {plan.namespace}/{plan.target_name}",
            ]
        )
    else:
        body.append("Action: none")

    body.extend(
        [
            "",
            "POLICY",
            f"Decision: {policy.result.value if policy else 'pending'}",
            f"Reason: {policy.reason if policy else 'pending'}",
            "",
            "RESULT",
            f"Success: {result.get('success', 'pending')}",
            f"Message: {result.get('message', 'pending')}",
        ]
    )

    if incident.status.value == "pending_approval":
        body.extend(["", "ACTION REQUIRED", "Review and approve/reject:", link])
    else:
        body.extend(
            [
                "",
                "FULL INCIDENT VIEW",
                f"{settings.dashboard_base_url}/incidents/{incident.id}",
                "",
                "This report was generated automatically by Autonomous-SRE.",
            ]
        )

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
