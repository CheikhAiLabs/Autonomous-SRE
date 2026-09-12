apiVersion: v1
kind: Secret
metadata:
  name: autonomous-sre-secrets
  namespace: sre-system
type: Opaque
stringData:
  POSTGRES_PASSWORD: "${POSTGRES_PASSWORD}"
  SMTP_PASSWORD: "${SMTP_PASSWORD}"
  APPROVAL_SIGNING_KEY: "${APPROVAL_SIGNING_KEY}"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: autonomous-sre-config
  namespace: sre-system
data:
  ALERT_EMAIL: "${ALERT_EMAIL}"
  SMTP_SMARTHOST: "${SMTP_SMARTHOST}"
  SMTP_USERNAME: "${SMTP_USERNAME}"
  SMTP_FROM: "${SMTP_USERNAME}"
  DASHBOARD_BASE_URL: "https://${PLATFORM_FQDN}"
  AUTO_REMEDIATION_MODE: "${AUTO_REMEDIATION_MODE}"
  OLLAMA_MODEL: "${OLLAMA_MODEL}"
  OLLAMA_URL: "http://ollama.sre-system.svc:11434"
  OPA_URL: "http://opa.sre-system.svc:8181"
  NATS_URL: "nats://nats.sre-system.svc:4222"
  PROMETHEUS_URL: "http://kube-prometheus-stack-prometheus.monitoring.svc:9090"
  ACTION_CATALOG_PATH: "/app/remediation/catalog.yaml"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: autonomous-sre-api
  namespace: sre-system
spec:
  replicas: 2
  selector:
    matchLabels: {app.kubernetes.io/name: autonomous-sre-api}
  template:
    metadata:
      labels: {app.kubernetes.io/name: autonomous-sre-api}
    spec:
      securityContext:
        runAsNonRoot: true
        seccompProfile: {type: RuntimeDefault}
      imagePullSecrets:
        - name: ghcr-pull
      containers:
        - name: api
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: {drop: ["ALL"]}
          image: ${IMAGE_PREFIX}/sre-api:${IMAGE_TAG}
          imagePullPolicy: Always
          ports:
            - {name: http, containerPort: 8000}
          envFrom:
            - configMapRef: {name: autonomous-sre-config}
          env:
            - name: POSTGRES_PASSWORD
              valueFrom: {secretKeyRef: {name: autonomous-sre-secrets, key: POSTGRES_PASSWORD}}
            - name: DATABASE_URL
              value: postgresql+asyncpg://autonomous_sre:$(POSTGRES_PASSWORD)@postgres.sre-system.svc:5432/autonomous_sre
            - name: SMTP_PASSWORD
              valueFrom: {secretKeyRef: {name: autonomous-sre-secrets, key: SMTP_PASSWORD}}
            - name: APPROVAL_SIGNING_KEY
              valueFrom: {secretKeyRef: {name: autonomous-sre-secrets, key: APPROVAL_SIGNING_KEY}}
          readinessProbe:
            httpGet: {path: /healthz, port: http}
            initialDelaySeconds: 5
            periodSeconds: 5
          resources:
            requests: {cpu: 100m, memory: 128Mi}
            limits: {memory: 512Mi}
---
apiVersion: v1
kind: Service
metadata:
  name: autonomous-sre-api
  namespace: sre-system
spec:
  selector: {app.kubernetes.io/name: autonomous-sre-api}
  ports:
    - {name: http, port: 8000, targetPort: http}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: autonomous-sre-worker
  namespace: sre-system
spec:
  replicas: 1
  selector:
    matchLabels: {app.kubernetes.io/name: autonomous-sre-worker}
  template:
    metadata:
      labels: {app.kubernetes.io/name: autonomous-sre-worker}
    spec:
      securityContext:
        runAsNonRoot: true
        seccompProfile: {type: RuntimeDefault}
      imagePullSecrets:
        - name: ghcr-pull
      containers:
        - name: worker
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: {drop: ["ALL"]}
          image: ${IMAGE_PREFIX}/sre-worker:${IMAGE_TAG}
          imagePullPolicy: Always
          envFrom:
            - configMapRef: {name: autonomous-sre-config}
          env:
            - name: POSTGRES_PASSWORD
              valueFrom: {secretKeyRef: {name: autonomous-sre-secrets, key: POSTGRES_PASSWORD}}
            - name: DATABASE_URL
              value: postgresql+asyncpg://autonomous_sre:$(POSTGRES_PASSWORD)@postgres.sre-system.svc:5432/autonomous_sre
            - name: SMTP_PASSWORD
              valueFrom: {secretKeyRef: {name: autonomous-sre-secrets, key: SMTP_PASSWORD}}
            - name: APPROVAL_SIGNING_KEY
              valueFrom: {secretKeyRef: {name: autonomous-sre-secrets, key: APPROVAL_SIGNING_KEY}}
          resources:
            requests: {cpu: 100m, memory: 256Mi}
            limits: {memory: 1Gi}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: remediation-controller
  namespace: sre-system
spec:
  replicas: 1
  selector:
    matchLabels: {app.kubernetes.io/name: remediation-controller}
  template:
    metadata:
      labels: {app.kubernetes.io/name: remediation-controller}
    spec:
      securityContext:
        runAsNonRoot: true
        seccompProfile: {type: RuntimeDefault}
      imagePullSecrets:
        - name: ghcr-pull
      serviceAccountName: remediation-controller
      containers:
        - name: controller
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: {drop: ["ALL"]}
          image: ${IMAGE_PREFIX}/remediation-controller:${IMAGE_TAG}
          imagePullPolicy: Always
          envFrom:
            - configMapRef: {name: autonomous-sre-config}
          resources:
            requests: {cpu: 100m, memory: 128Mi}
            limits: {memory: 512Mi}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: autonomous-sre-dashboard
  namespace: sre-system
spec:
  replicas: 2
  selector:
    matchLabels: {app.kubernetes.io/name: autonomous-sre-dashboard}
  template:
    metadata:
      labels: {app.kubernetes.io/name: autonomous-sre-dashboard}
    spec:
      securityContext:
        runAsNonRoot: true
        seccompProfile: {type: RuntimeDefault}
      imagePullSecrets:
        - name: ghcr-pull
      containers:
        - name: dashboard
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: {drop: ["ALL"]}
          image: ${IMAGE_PREFIX}/dashboard:${IMAGE_TAG}
          imagePullPolicy: Always
          ports:
            - {name: http, containerPort: 8080}
          readinessProbe:
            httpGet: {path: /healthz, port: http}
            initialDelaySeconds: 3
            periodSeconds: 5
          resources:
            requests: {cpu: 50m, memory: 64Mi}
            limits: {memory: 256Mi}
---
apiVersion: v1
kind: Service
metadata:
  name: autonomous-sre-dashboard
  namespace: sre-system
spec:
  selector: {app.kubernetes.io/name: autonomous-sre-dashboard}
  ports:
    - {name: http, port: 8080, targetPort: http}
