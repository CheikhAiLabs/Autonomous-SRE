FROM node:22-alpine AS build
WORKDIR /app
COPY apps/dashboard/package*.json ./
RUN npm install --no-audit --no-fund
COPY apps/dashboard/ ./
RUN npm run build

FROM nginxinc/nginx-unprivileged:1.29-alpine
COPY apps/dashboard/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html
EXPOSE 8080
