apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ollama-data
  namespace: sre-system
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: local-path
  resources:
    requests: {storage: 20Gi}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ollama
  namespace: sre-system
spec:
  replicas: 1
  selector:
    matchLabels: {app: ollama}
  template:
    metadata:
      labels: {app: ollama}
    spec:
      nodeSelector:
        autonomous-sre/role: worker
      containers:
        - name: ollama
          image: ollama/ollama:0.34.0
          ports:
            - {name: http, containerPort: 11434}
          env:
            - {name: OLLAMA_KEEP_ALIVE, value: "24h"}
            - {name: OLLAMA_NUM_PARALLEL, value: "1"}
          volumeMounts:
            - {name: data, mountPath: /root/.ollama}
          resources:
            requests: {cpu: "500m", memory: 2Gi}
            limits: {memory: 7Gi}
      volumes:
        - name: data
          persistentVolumeClaim: {claimName: ollama-data}
---
apiVersion: v1
kind: Service
metadata:
  name: ollama
  namespace: sre-system
spec:
  selector: {app: ollama}
  ports:
    - {name: http, port: 11434, targetPort: http}
