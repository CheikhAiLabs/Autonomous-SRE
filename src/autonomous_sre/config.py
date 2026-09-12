from functools import lru_cache

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=None, extra="ignore", case_sensitive=False)

    environment: str = "production"
    log_level: str = "INFO"
    database_url: str = "postgresql+asyncpg://autonomous_sre:autonomous_sre@postgres:5432/autonomous_sre"
    nats_url: str = "nats://nats:4222"
    prometheus_url: str = "http://kube-prometheus-stack-prometheus.monitoring.svc:9090"
    opa_url: str = "http://opa.sre-system.svc:8181"
    ollama_url: str = "http://ollama.sre-system.svc:11434"
    ollama_model: str = "qwen3:4b"
    alert_email: str = "cheikhminator@gmail.com"
    smtp_smarthost: str = "smtp.gmail.com:587"
    smtp_username: str = ""
    smtp_password: str = ""
    smtp_from: str = ""
    dashboard_base_url: str = "https://localhost"
    approval_signing_key: str = Field(min_length=32)
    approval_token_ttl_seconds: int = 1800
    auto_remediation_mode: str = "autonomous-low-risk"
    incident_poll_interval_seconds: int = 15
    incident_cooldown_seconds: int = 300
    recovery_verify_seconds: int = 90
    action_catalog_path: str = "/app/remediation/catalog.yaml"


@lru_cache
def get_settings() -> Settings:
    return Settings()
