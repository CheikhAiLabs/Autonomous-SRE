apiVersion: v1
kind: Secret
metadata:
  name: postgres-secret
  namespace: sre-system
type: Opaque
stringData:
  POSTGRES_PASSWORD: "${POSTGRES_PASSWORD}"
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
  namespace: sre-system
spec:
  serviceName: postgres
  replicas: 1
  selector:
    matchLabels: {app: postgres}
  template:
    metadata:
      labels: {app: postgres}
    spec:
      containers:
        - name: postgres
          image: postgres:18-alpine
          env:
            - {name: POSTGRES_DB, value: autonomous_sre}
            - {name: POSTGRES_USER, value: autonomous_sre}
            - {name: PGDATA, value: /var/lib/postgresql/18/docker}
            - name: POSTGRES_PASSWORD
              valueFrom: {secretKeyRef: {name: postgres-secret, key: POSTGRES_PASSWORD}}
          ports:
            - {name: postgres, containerPort: 5432}
          readinessProbe:
            exec: {command: ["pg_isready", "-U", "autonomous_sre"]}
            initialDelaySeconds: 5
            periodSeconds: 5
          volumeMounts:
            - {name: data, mountPath: /var/lib/postgresql}
          resources:
            requests: {cpu: 100m, memory: 256Mi}
            limits: {memory: 1Gi}
  volumeClaimTemplates:
    - metadata: {name: data}
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: local-path
        resources:
          requests: {storage: 8Gi}
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: sre-system
spec:
  selector: {app: postgres}
  ports:
    - {name: postgres, port: 5432, targetPort: postgres}
