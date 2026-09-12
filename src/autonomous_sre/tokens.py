import base64
import hashlib
import hmac
import json
import time
from uuid import UUID

from autonomous_sre.config import get_settings


def _b64url_encode(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).decode().rstrip("=")


def _b64url_decode(value: str) -> bytes:
    padded = value + "=" * (-len(value) % 4)
    return base64.urlsafe_b64decode(padded.encode())


def create_approval_token(incident_id: UUID) -> str:
    settings = get_settings()
    payload = {
        "incident_id": str(incident_id),
        "exp": int(time.time()) + settings.approval_token_ttl_seconds,
    }
    raw = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode()
    sig = hmac.new(settings.approval_signing_key.encode(), raw, hashlib.sha256).digest()
    return f"{_b64url_encode(raw)}.{_b64url_encode(sig)}"


def verify_approval_token(token: str, incident_id: UUID) -> bool:
    settings = get_settings()
    try:
        raw_part, sig_part = token.split(".", 1)
        raw = _b64url_decode(raw_part)
        sig = _b64url_decode(sig_part)
        expected = hmac.new(settings.approval_signing_key.encode(), raw, hashlib.sha256).digest()
        if not hmac.compare_digest(sig, expected):
            return False
        payload = json.loads(raw.decode())
        return payload["incident_id"] == str(incident_id) and int(payload["exp"]) >= int(time.time())
    except (ValueError, KeyError, TypeError, json.JSONDecodeError):
        return False
