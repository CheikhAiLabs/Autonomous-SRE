FROM python:3.13-slim
WORKDIR /app
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
    && rm -rf /var/lib/apt/lists/* \
    && python -m pip install --no-cache-dir --upgrade pip "setuptools>=78.1.1" uv \
    && groupadd --system --gid 10001 app \
    && useradd --system --uid 10001 --gid 10001 --home-dir /app --shell /usr/sbin/nologin app
COPY pyproject.toml ./
COPY src ./src
COPY apps ./apps
COPY remediation ./remediation
RUN uv pip install --system . \
    && rm -rf /root/.cache/uv /root/.cache/pip \
    && chown -R 10001:10001 /app
USER 10001:10001
CMD ["python", "-m", "apps.controller.main"]
