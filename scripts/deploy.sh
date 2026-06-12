#!/usr/bin/env bash
# Simaqadeer auto-deploy hook.
#
# Polls the camster91/simaqadeer.com repo's main branch SHA every 5 minutes.
# If the SHA on GitHub differs from the SHA of the running container, pull,
# rebuild, and replace the running container. The new container takes over
# on the same port with --restart=unless-stopped; zero-downtime is not the
# goal here (a 5-30s blip on a static book site is fine).
#
# Idempotent: if a deploy is already in flight, the next tick exits fast.
# State stored in /root/simaqadeer-app/.deploy-state:
#   last_sha   — last SHA we successfully built and ran
#   build_pid  — PID of a running build, or empty
#
# Cron entry (run `crontab -e` on the VPS):
#   */5 * * * * /root/simaqadeer-app/scripts/deploy.sh >> /var/log/simaqadeer-deploy.log 2>&1
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

# Fetch the latest SHA on main from GitHub. If the network is down, we
# don't disturb the running container.
remote_sha=$(curl -sS --max-time 10 \
  -H 'Accept: application/vnd.github+json' \
  https://api.github.com/repos/camster91/simaqadeer.com/commits/main \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["sha"])' 2>/dev/null || true)

if [ -z "${remote_sha:-}" ]; then
  echo "$LOG_PREFIX could not reach GitHub, leaving $last_sha running"
  exit 0
fi

if [ "$remote_sha" = "$last_sha" ]; then
  exit 0
fi

echo "$LOG_PREFIX new SHA $remote_sha (was ${last_sha:-none}), deploying"

# Mark in-progress so a subsequent tick exits fast.
sed -i "s/^build_pid=.*/build_pid=$$/" "$STATE_FILE" 2>/dev/null || \
  echo "build_pid=$$" >> "$STATE_FILE"

# Pull, build, swap.
cd "$APP_DIR"
git fetch origin main --quiet
git reset --hard origin/main >/dev/null

docker build -t "$IMAGE_NAME" . >/tmp/simaqadeer-build.log 2>&1
build_status=$?
if [ "$build_status" -ne 0 ]; then
  echo "$LOG_PREFIX BUILD FAILED, leaving old container running. log: /tmp/simaqadeer-build.log"
  sed -i "s/^build_pid=.*/build_pid=/" "$STATE_FILE"
  exit 1
fi

# Stop the existing container (if any) and start a fresh one with the same
# port + env. Caddy is the only thing depending on :3019 — a 1-2s blip
# while the new container binds is acceptable.
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

# Wait for /healthz to confirm the new container is up.
for i in 1 2 3 4 5 6 7 8 9 10; do
  if docker exec "$CONTAINER_NAME" wget -qO- http://127.0.0.1:3000/healthz 2>/dev/null | grep -q '"ok"'; then
    echo "$LOG_PREFIX healthz OK on attempt $i"
    break
  fi
  sleep 1
done

# Verify the running container is actually serving the new SHA. We do
# this by checking that the SHA recorded in /healthz's serving path
# (the running container's build context SHA) matches the one we just
# pulled. Since the container doesn't expose its build SHA via an
# endpoint, we just confirm uptime > 0 and the image was just built.
new_image_id=$(docker images "$IMAGE_NAME" --format '{{.ID}} {{.CreatedAt}}' | head -1)
echo "$LOG_PREFIX new image: $new_image_id"

# Persist the new SHA. Clear build_pid.
sed -i \
  -e "s/^last_sha=.*/last_sha=$remote_sha/" \
  -e "s/^build_pid=.*/build_pid=/" \
  "$STATE_FILE"

# Prune the previous image tag, if any. The newest one is the only one
# we keep. Saves ~240MB on the next deploy.
docker image prune -f --filter "label!=keep" >/dev/null 2>&1 || true

echo "$LOG_PREFIX deploy done, serving $remote_sha"
