apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-production
spec:
  acme:
    email: ${LETSENCRYPT_EMAIL}
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-production-account
    solvers:
      - http01:
          gatewayHTTPRoute:
            parentRefs:
              - name: autonomous-sre
                namespace: sre-system
                kind: Gateway
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: autonomous-sre
  namespace: sre-system
spec:
  gatewayClassName: cilium
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces: {from: Same}
    - name: https
      protocol: HTTPS
      port: 443
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: autonomous-sre-tls
      allowedRoutes:
        namespaces: {from: Same}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: autonomous-sre
  namespace: sre-system
spec:
  secretName: autonomous-sre-tls
  dnsNames: ["${PLATFORM_FQDN}"]
  issuerRef:
    name: letsencrypt-production
    kind: ClusterIssuer
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: autonomous-sre-http
  namespace: sre-system
spec:
  parentRefs:
    - name: autonomous-sre
      sectionName: http
  hostnames: ["${PLATFORM_FQDN}"]
  rules:
    - filters:
        - type: RequestRedirect
          requestRedirect:
            scheme: https
            statusCode: 301
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: autonomous-sre-https
  namespace: sre-system
spec:
  parentRefs:
    - name: autonomous-sre
      sectionName: https
  hostnames: ["${PLATFORM_FQDN}"]
  rules:
    - matches:
        - path: {type: PathPrefix, value: /api}
      backendRefs:
        - name: autonomous-sre-api
          port: 8000
    - backendRefs:
        - name: autonomous-sre-dashboard
          port: 8080
