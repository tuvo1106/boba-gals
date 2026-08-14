# The `boba-frontend` image (DESIGN.md §14.1): the Vite build served by nginx.
#
# nginx proxies nothing — routing /api and /cable to the API is the ingress's
# job (§14.2). This container serves static files and nothing else.

# Keep in sync with .node-version at the repo root.
ARG NODE_VERSION=24.19.0
FROM docker.io/library/node:$NODE_VERSION-slim AS build

WORKDIR /frontend

COPY package.json package-lock.json ./
# --legacy-peer-deps: openapi-typescript's peerDependencies caps at
# typescript ^5.x and hasn't caught up to this repo's ~6.0.2 yet (ADR-0030).
RUN npm ci --legacy-peer-deps

COPY . .
RUN npm run build


FROM docker.io/library/nginx:1.27-alpine AS production

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /frontend/dist /usr/share/nginx/html

EXPOSE 80
