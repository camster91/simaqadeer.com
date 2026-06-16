#!/usr/bin/env bash
# simaqadeer.com Caddyfile guard.
#
# Re-adds the simaqadeer.ashbi.ca Caddy route to /opt/caddy/Caddyfile
# if a fleet-wide edit (e.g. jwhabits / markup / lull / contractions
# caddy-guard cron jobs) wipes it. Mirrors the same pattern.
#
# Cron entry (one row, /etc/cron.d/simaqadeer-caddy-guard):
#   * * * * * /root/simaqadeer-app/scripts/caddy-guard.sh >> /var/log/simaqadeer-caddy-guard.log 2>&1
#
# Why every minute: matches the sibling-guard cadence. Worst-case
# missing-route window is 60 seconds. The caddy reload is only
# triggered if the file changed, so the steady-state cost is one
# grep per minute.
#
# Env vars (override before cron):
#   SIMA_HOSTNAME   default simaqadeer.ashbi.ca
#   SIMA_WWW        default www.simaqadeer.ashbi.ca
#   LIVE_CADDYFILE  default /opt/caddy/Caddyfile

set -euo pipefail

SIMA_HOSTNAME="${SIMA_HOSTNAME:-simaqadeer.ashbi.ca}"
SIMA_WWW="${SIMA_WWW:-www.simaqadeer.ashbi.ca}"
LIVE_CADDYFILE="${LIVE_CADDYFILE:-/opt/caddy/Caddyfile}"
LOG_PREFIX="[$(date -u +%Y-%m-%dT%H:%M:%SZ)]"

changed=0
[ -f "$LIVE_CADDYFILE" ] || { echo "$LOG_PREFIX $LIVE_CADDYFILE not found"; exit 0; }

# The block we defend. Single source of truth: if you change the
# route, change it here AND in scripts/deploy.sh.
SIMA_BLOCK="$(cat <<'BLOCK_EOF'

# simaqadeer.com author site (managed by /root/simaqadeer-app/scripts/caddy-guard.sh)
simaqadeer.ashbi.ca, www.simaqadeer.ashbi.ca {
    encode gzip zstd
    reverse_proxy 127.0.0.1:3019
    @assets {
        path *.css *.js *.svg *.png *.jpg *.jpeg *.webp *.otf *.woff2 *.ico
    }
    header @assets Cache-Control "public, max-age=31536000, immutable"
    header {
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
BLOCK_EOF
)"

if ! grep -qE "^${SIMA_HOSTNAME//./\\.}" "$LIVE_CADDYFILE" 2>/dev/null; then
  echo "$LOG_PREFIX missing ${SIMA_HOSTNAME} route in $LIVE_CADDYFILE, re-adding"
  printf '%s\n' "$SIMA_BLOCK" >> "$LIVE_CADDYFILE"
  changed=1
fi

# Caddy may also still have the OLD single-host block (simaqadeer.ashbi.ca
# without www.). Detect and remove it so the wide form is canonical.
if grep -qE "^simaqadeer\\.ashbi\\.ca\\s*\\{" "$LIVE_CADDYFILE" 2>/dev/null; then
  if ! grep -qE "^simaqadeer\\.ashbi\\.ca,\\s*www\\.simaqadeer\\.ashbi\\.ca" "$LIVE_CADDYFILE"; then
    echo "$LOG_PREFIX found stale single-host sima block, replacing with wide form"
    python3 - <<PYEOF
import re
with open("$LIVE_CADDYFILE") as f: c = f.read()
new = re.sub(
    r"\n\n# simaqadeer\.com author site.*?^}\n",
    "$SIMA_BLOCK\\n",
    c,
    count=1,
    flags=re.S | re.M,
)
with open("$LIVE_CADDYFILE", "w") as f: f.write(new)
PYEOF
    changed=1
  fi
fi

[ "$changed" -eq 0 ] && exit 0

# File changed. Soft-reload via admin API, fall back to systemctl.
if curl -sf --max-time 1 http://127.0.0.1:2019/config/ >/dev/null 2>&1; then
  if caddy adapt --config "$LIVE_CADDYFILE" --pretty 2>/dev/null > /tmp/simaqadeer-caddy-guard.json; then
    if curl -sf -X POST -H "Content-Type: application/json" --data @/tmp/simaqadeer-caddy-guard.json http://127.0.0.1:2019/load >/dev/null 2>&1; then
      echo "$LOG_PREFIX caddy reloaded via admin API"
    else
      echo "$LOG_PREFIX admin API POST failed; falling back to systemctl restart caddy"
      systemctl restart caddy >/dev/null 2>&1 || true
    fi
  else
    echo "$LOG_PREFIX caddy adapt failed; falling back to systemctl restart"
    systemctl restart caddy >/dev/null 2>&1 || true
  fi
else
  systemctl restart caddy >/dev/null 2>&1 && echo "$LOG_PREFIX caddy restarted" || echo "$LOG_PREFIX caddy restart failed"
fi

