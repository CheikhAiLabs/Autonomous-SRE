FROM python:3.13-slim
WORKDIR /app
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
RUN pip install --no-cache-dir uv \
    && groupadd --system --gid 10001 app \
    && useradd --system --uid 10001 --gid 10001 --home-dir /app --shell /usr/sbin/nologin app
COPY pyproject.toml ./
COPY src ./src
COPY apps ./apps
COPY remediation ./remediation
RUN uv pip install --system . && chown -R 10001:10001 /app
USER 10001:10001
CMD ["uvicorn", "apps.api.main:app", "--host", "0.0.0.0", "--port", "8000"]
