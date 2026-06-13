#!/usr/bin/env bash
# Simaqadeer auto-deploy hook.
#
# Polls the camster91/simaqadeer.com repo's main branch SHA every 5 minutes.
# If the SHA on GitHub differs from the SHA of the running container, pull,
# rebuild, and replace the running container. The new container takes over
# on the same port with --restart=unless-stopped; zero-downtime is not the
# goal here (a 5-30s blip on a static book site is fine).
#
# ALSO: the Caddyfile at /opt/caddy/Caddyfile is shared across the Ashbi
# fleet. Other agents/Cam are actively editing it. This script also
# ensures the simaqadeer route is present (idempotent — re-adds if a
# fleet-wide edit dropped it) and restarts Caddy if the file changed.
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
CADDYFILE="/opt/caddy/Caddyfile"
LOG_PREFIX="[$(date -u +%Y-%m-%dT%H:%M:%SZ)]"

# The route block this script defends. Single source of truth — if you
# need to change the route, change it here and on every VPS deploy.
# Currently scoped to the Ashbi subdomain only; the apex
# simaqadeer.com is dormant until Cam flips the NameCheap A record
# to 187.77.26.99 — at that point, add `simaqadeer.com,
# www.simaqadeer.com,` to the host list and the cert + routing come
# up automatically.
read -r -d '' SIMA_BLOCK <<'EOF' || true

# simaqadeer.com author site (managed by /root/simaqadeer-app/scripts/deploy.sh)
simaqadeer.ashbi.ca, www.simaqadeer.ashbi.ca {
    encode gzip zstd
    reverse_proxy 127.0.0.1:3019
    @assets {
        path *.css *.js *.svg *.png *.jpg *.jpeg *.webp *.otf *.woff2 *.ico
    }
    header @assets Cache-Control "public, max-age=31536000, immutable"
    header {
        # CSP matches the site's actual outbound destinations:
        # - default 'self' so we deny anything we haven't thought about
        # - script 'self' + 'unsafe-inline' + 'unsafe-eval' for the
        #   React bundle's runtime (Vite output)
        # - style 'self' + 'unsafe-inline' for Tailwind + Google Fonts CSS
        # - font 'self' + Google Fonts (fonts.gstatic.com) + data URIs
        # - img 'self' + data: + https: (book cover from any CDN if
        #   Indigo/Amazon etc are added later; cover.jpg and og-image
        #   are local but the press kit links go offsite)
        # - connect 'self' for the /api/contact POST
        # - frame-ancestors 'none' so the site can't be iframed
        # - form-action 'self' so the contact form can only POST to us
        # - object-src 'none' so no Flash/legacy plugins
        Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src 'self' https://fonts.gstatic.com data:; img-src 'self' data: https:; connect-src 'self'; frame-ancestors 'none'; form-action 'self'; object-src 'none'; base-uri 'self'"
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        X-Frame-Options "SAMEORIGIN"
        X-Content-Type-Options "nosniff"
        Referrer-Policy "strict-origin-when-cross-origin"
    }
    log {
        output file /data/simaqadeer.ashbi.ca.log {
            roll_size 50mb
            roll_keep 5
        }
    }
}
EOF

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

# ----- Step 1: ensure the Caddy route is present -----
# A fleet-wide Caddyfile edit (e.g. another agent adding a new block)
# can drop our route. We re-add it idempotently on every tick.
caddyfile_changed=0
if [ -f "$CADDYFILE" ] && ! grep -q "simaqadeer\.ashbi\.ca" "$CADDYFILE"; then
  echo "$LOG_PREFIX Caddyfile missing sima block, re-adding"
  cp "$CADDYFILE" "${CADDYFILE}.bak.$(date -u +%Y%m%d_%H%M%S)"
  printf '\n%s\n' "$SIMA_BLOCK" >> "$CADDYFILE"
  caddyfile_changed=1
fi

# ----- Step 2: check for a new SHA on main -----
remote_sha=$(curl -sS --max-time 10 \
  -H 'Accept: application/vnd.github+json' \
  https://api.github.com/repos/camster91/simaqadeer.com/commits/main \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["sha"])' 2>/dev/null || true)

if [ -z "${remote_sha:-}" ]; then
  echo "$LOG_PREFIX could not reach GitHub, leaving $last_sha running"
  # Still restart Caddy if we changed the Caddyfile above.
  if [ "$caddyfile_changed" -eq 1 ]; then
    systemctl restart caddy && echo "$LOG_PREFIX Caddy restarted"
  fi
  exit 0
fi

# ----- Step 3: rebuild + swap if SHA changed -----
if [ "$remote_sha" != "$last_sha" ]; then
  echo "$LOG_PREFIX new SHA $remote_sha (was ${last_sha:-none}), deploying"

  sed -i "s/^build_pid=.*/build_pid=$$/" "$STATE_FILE" 2>/dev/null || \
    echo "build_pid=$$" >> "$STATE_FILE"

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

# ----- Step 4: restart Caddy if the Caddyfile was changed (always, not just on deploy) -----
if [ "$caddyfile_changed" -eq 1 ]; then
  systemctl restart caddy && echo "$LOG_PREFIX Caddy restarted (Caddyfile was missing sima block)"
fi
