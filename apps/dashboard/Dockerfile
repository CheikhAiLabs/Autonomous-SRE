FROM node:26-alpine AS build
WORKDIR /app
COPY apps/dashboard/package*.json ./
RUN npm ci --no-audit --no-fund
COPY apps/dashboard/ ./
RUN sed -i 's#http://127.0.0.1:4466/kubernetes/#/kubernetes/#g; s#Run make headlamp locally first#Open Kubernetes Explorer#g' src/main.tsx \
    && npm run build

FROM nginxinc/nginx-unprivileged:1.29-alpine
USER root
RUN apk upgrade --no-cache
COPY apps/dashboard/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html
USER 101
EXPOSE 8080
