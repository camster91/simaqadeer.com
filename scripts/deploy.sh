#!/usr/bin/env bash
# Simaqadeer auto-deploy hook.
#
# Polls the camster91/simaqadeer.com repo's main branch SHA every 5 minutes.
# If the SHA on GitHub differs from the SHA of the running container, pull,
# rebuild, and replace the running container. The new container takes over
# on the same port with --restart=unless-stopped; zero-downtime is not the
# goal here (a 5-30s blip on a static book site is fine).
#
# Traefik (Docker container, mounts /opt/traefik/{traefik.yml,dynamic} from
# the host) is the edge reverse proxy. Sima routes live in
# /opt/traefik/dynamic/routers.yml with the simaqadeer-csp middleware
# (CSP + HSTS + X-Frame-Options + X-Content-Type-Options + Referrer-Policy)
# and the simaqadeer-assets middleware (asset Cache-Control). This hook
# does NOT touch the Traefik config — that's managed by render.py from
# /opt/vps/manifest/sites.yaml, separately.
#
# The prior version of this script defended a Caddy site block at
# /opt/caddy/Caddyfile. Caddy is masked on the VPS; Traefik serves :80
# and :443. The Caddy code was removed 2026-06-23.
#
# Idempotent: if a deploy is already in flight, the next tick exits fast.
# State stored in /root/simaqadeer-app/.deploy-state:
#   last_sha   — last SHA we successfully built and ran
#   build_pid  — PID of a running build, or empty
#
# Cron entry at /etc/cron.d/simaqadeer-deploy:
#   */5 * * * * root /root/simaqadeer-app/scripts/deploy.sh >> /var/log/simaqadeer-deploy.log 2>&1
#
# To force a rebuild without a code change, bump /tmp/simaqadeer-deploy-trigger.

set -euo pipefail

APP_DIR="/root/simaqadeer-app"
IMAGE_NAME="simaqadeer-app:local"
CONTAINER_NAME="simaqadeer-app"
STATE_FILE="$APP_DIR/.deploy-state"
LOCK_FILE="/var/lock/simaqadeer-deploy.lock"
LOG_PREFIX="[$(date -u +%Y-%m-%dT%H:%M:%SZ)]"

# Ensure state dir + file exist.
mkdir -p "$(dirname "$STATE_FILE")"
touch "$STATE_FILE"

# Read prior state.
last_sha=$(grep -oE 'last_sha=[a-f0-9]+' "$STATE_FILE" 2>/dev/null | cut -d= -f2 || true)
build_pid=$(grep -oE 'build_pid=[0-9]+' "$STATE_FILE" 2>/dev/null | cut -d= -f2 || true)

# If a previous build is still running, exit fast.
if [ -n "${build_pid:-}" ] && kill -0 "$build_pid" 2>/dev/null; then
  echo "$LOG_PREFIX build still running (pid=$build_pid), skipping"
  exit 0
fi

# Acquire lock so concurrent runs (cron + manual) don't collide.
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "$LOG_PREFIX another deploy is holding the lock, skipping"
  exit 0
fi

# ----- Step 1: check for a new SHA on main -----
# Capture HTTP status separately from the JSON parse — GitHub's unauthenticated
# /repos/.../commits endpoint is rate-limited to 60 req/hr. A 403/429 here
# used to fail silently (the python3 parse errored, `|| true` swallowed it,
# `remote_sha` became empty, the script logged "could not reach GitHub" and
# exited 0). Now we check the status first and exit non-zero on rate-limit
# so cron + log readers see the failure.
remote_body=$(curl -sS --max-time 10 -w '\n%{http_code}' \
  -H 'Accept: application/vnd.github+json' \
  https://api.github.com/repos/camster91/simaqadeer.com/commits/main 2>/dev/null || true)
remote_status=$(echo "$remote_body" | tail -n 1)
remote_json=$(echo "$remote_body" | sed '$d')
remote_sha=$(echo "$remote_json" | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin)["sha"])
except Exception:
    pass' 2>/dev/null || true)

if [ -z "${remote_sha:-}" ]; then
  echo "$LOG_PREFIX could not fetch remote SHA (HTTP $remote_status), leaving ${last_sha:-none} running"
  # Non-zero exit on rate-limit so the cron log shows the failure distinctly.
  if [ "${remote_status:-}" = "403" ] || [ "${remote_status:-}" = "429" ]; then
    echo "$LOG_PREFIX GitHub rate-limited — back off for an hour, do not retry"
    exit 1
  fi
  exit 0
fi

# ----- Step 2: rebuild + swap if SHA changed -----
if [ "$remote_sha" != "$last_sha" ]; then
  echo "$LOG_PREFIX new SHA $remote_sha (was ${last_sha:-none}), deploying"

  sed -i "s/^build_pid=.*/build_pid=$$/" "$STATE_FILE" 2>/dev/null || \
    echo "build_pid=$$" >> "$STATE_FILE"

  cd "$APP_DIR"
  git fetch origin main --quiet
  git reset --hard origin/main >/dev/null

  # Verify the reset actually landed — `git reset --hard` can silently no-op
  # if the remote ref hasn't moved (rare, but worth catching so a broken
  # deploy hook doesn't keep running old code forever).
  actual_sha=$(git rev-parse HEAD)
  if [ "$actual_sha" != "$remote_sha" ]; then
    echo "$LOG_PREFIX reset landed at $actual_sha, expected $remote_sha — bailing, leaving old container running"
    sed -i "s/^build_pid=.*/build_pid=/" "$STATE_FILE"
    exit 1
  fi

  docker build -t "$IMAGE_NAME" . >/tmp/simaqadeer-build.log 2>&1
  build_status=$?
  if [ "$build_status" -ne 0 ]; then
    echo "$LOG_PREFIX BUILD FAILED, leaving old container running. log: /tmp/simaqadeer-build.log"
    sed -i "s/^build_pid=.*/build_pid=/" "$STATE_FILE"
    exit 1
  fi

  if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}\$"; then
    docker stop "$CONTAINER_NAME" >/dev/null
    docker rm "$CONTAINER_NAME" >/dev/null
  fi

  docker run -d \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    -p 127.0.0.1:3019:3000 \
    -e NODE_ENV=production \
    -e PORT=3000 \
    -e CONTACT_EMAIL=simaqadeerAuthor@gmail.com \
    "$IMAGE_NAME" >/dev/null

  for i in 1 2 3 4 5 6 7 8 9 10; do
    if docker exec "$CONTAINER_NAME" wget -qO- http://127.0.0.1:3000/healthz 2>/dev/null | grep -q '"ok"'; then
      echo "$LOG_PREFIX healthz OK on attempt $i"
      break
    fi
    sleep 1
  done

  new_image_id=$(docker images "$IMAGE_NAME" --format '{{.ID}} {{.CreatedAt}}' | head -1)
  echo "$LOG_PREFIX new image: $new_image_id"

  sed -i \
    -e "s/^last_sha=.*/last_sha=$remote_sha/" \
    -e "s/^build_pid=.*/build_pid=/" \
    "$STATE_FILE"

  docker image prune -f --filter "label!=keep" >/dev/null 2>&1 || true

  echo "$LOG_PREFIX deploy done, serving $remote_sha"
fi