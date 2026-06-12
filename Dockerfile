# syntax=docker/dockerfile:1.7
# Multi-stage build for simaqadeer.com author site.
#
# Stage 1 (builder): install production deps into a known location.
# Stage 2 (runtime): node:alpine base, copy deps + server + public, run as non-root.
#
# Build:  docker build -t simaqadeer-app:local .
# Run:    docker run --rm -p 3000:3000 simaqadeer-app:local

# ---- Stage 1: deps ----
FROM node:22-alpine AS deps
WORKDIR /app

# Copy ONLY the manifest first so the install layer is cached across
# source-only changes. This is the standard Docker layer-cache pattern.
COPY package.json package-lock.json* ./
RUN \
  if [ -f package-lock.json ]; then npm ci --omit=dev; \
  else npm install --omit=dev; fi

# ---- Stage 2: runtime ----
FROM node:22-alpine AS runtime
WORKDIR /app

# Run as a non-root user. node:alpine ships with a `node` user (uid 1000).
# The Express server doesn't need filesystem writes, so this is safe.
ENV NODE_ENV=production \
    PORT=3000 \
    STATIC_DIR=/app/public

COPY --from=deps --chown=node:node /app/node_modules ./node_modules
COPY --chown=node:node server.js ./
COPY --chown=node:node public ./public

USER node

EXPOSE 3000

# Quick TCP-level health check. Hits /healthz which is the first cheap
# endpoint in server.js. 2s start period to let the server bind.
HEALTHCHECK --interval=30s --timeout=3s --start-period=2s --retries=3 \
  CMD wget -qO- http://127.0.0.1:3000/healthz || exit 1

CMD ["node", "server.js"]
