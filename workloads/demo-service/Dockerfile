FROM python:3.13-slim
WORKDIR /app
RUN pip install --no-cache-dir fastapi uvicorn prometheus-client \
    && groupadd --system --gid 10001 app \
    && useradd --system --uid 10001 --gid 10001 --home-dir /app --shell /usr/sbin/nologin app
COPY workloads/demo-service/main.py /app/main.py
RUN chown -R 10001:10001 /app
ENV ERROR_RATE=0 PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
USER 10001:10001
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
