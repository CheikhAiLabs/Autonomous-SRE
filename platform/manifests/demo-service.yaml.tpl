apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-service
  namespace: demo
  labels: {app: demo-service}
spec:
  replicas: 2
  revisionHistoryLimit: 5
  selector:
    matchLabels: {app: demo-service}
  template:
    metadata:
      labels: {app: demo-service}
    spec:
      securityContext:
        runAsNonRoot: true
        seccompProfile: {type: RuntimeDefault}
      nodeSelector:
        autonomous-sre/role: worker
      imagePullSecrets:
        - name: ghcr-pull
      containers:
        - name: demo-service
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: {drop: ["ALL"]}
          image: ${IMAGE_PREFIX}/demo-service:${IMAGE_TAG}
          imagePullPolicy: Always
          env:
            - {name: ERROR_RATE, value: "0"}
          ports:
            - {name: http, containerPort: 8080}
          readinessProbe:
            httpGet: {path: /healthz, port: http}
            initialDelaySeconds: 2
            periodSeconds: 3
          resources:
            requests: {cpu: 50m, memory: 64Mi}
            limits: {cpu: 500m, memory: 256Mi}
---
apiVersion: v1
kind: Service
metadata:
  name: demo-service
  namespace: demo
  labels: {app: demo-service}
spec:
  selector: {app: demo-service}
  ports:
    - {name: http, port: 8080, targetPort: http}
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: demo-service
  namespace: demo
  labels: {release: kube-prometheus-stack}
spec:
  selector:
    matchLabels: {app: demo-service}
  endpoints:
    - port: http
      path: /metrics
      interval: 5s
---
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: autonomous-sre-demo
  namespace: demo
  labels: {release: kube-prometheus-stack}
spec:
  groups:
    - name: autonomous-sre.demo
      rules:
        - alert: DemoServiceHigh5xxRate
          expr: (sum(rate(sre_demo_requests_total{status=~"5.."}[1m])) / sum(rate(sre_demo_requests_total[1m]))) > 0.20
          for: 20s
          labels:
            severity: critical
            sre_managed: "true"
            namespace: demo
            deployment: demo-service
          annotations:
            summary: "Demo service error rate exceeded 20% after a release"
            description: "The golden-path workload is returning a sustained high rate of HTTP 5xx responses."
            sre_action: "rollback_deployment"
            sre_risk: "low"
            sre_target_namespace: "demo"
            sre_target_kind: "Deployment"
            sre_target_name: "demo-service"
            sre_blast_radius: "1"
            sre_verify_query: 'sum(rate(sre_demo_requests_total{status=~"5.."}[1m])) / sum(rate(sre_demo_requests_total[1m]))'
            sre_verify_threshold: "0.10"
