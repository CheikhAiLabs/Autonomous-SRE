FROM python:3.14-slim
WORKDIR /app
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
    && rm -rf /var/lib/apt/lists/* \
    && python -m pip install --no-cache-dir --upgrade pip "setuptools>=78.1.1" \
    && pip install --no-cache-dir fastapi uvicorn prometheus-client "msgpack>=1.2.1" \
    && groupadd --system --gid 10001 app \
    && useradd --system --uid 10001 --gid 10001 --home-dir /app --shell /usr/sbin/nologin app \
    && rm -rf /root/.cache/pip
COPY workloads/demo-service/main.py /app/main.py
RUN chown -R 10001:10001 /app
ENV ERROR_RATE=0 PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
USER 10001:10001
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
