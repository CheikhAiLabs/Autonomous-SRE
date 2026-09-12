from uuid import uuid4

from autonomous_sre.tokens import create_approval_token, verify_approval_token


def test_approval_token_round_trip(monkeypatch):
    monkeypatch.setenv("APPROVAL_SIGNING_KEY", "test-key-that-is-long-enough-for-tests-123456")
    from autonomous_sre.config import get_settings
    get_settings.cache_clear()
    incident_id = uuid4()
    token = create_approval_token(incident_id)
    assert verify_approval_token(token, incident_id)
    assert not verify_approval_token(token, uuid4())
