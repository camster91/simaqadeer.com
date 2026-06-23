# simaqadeer-app

Node/Express wrapper around the static build at
[camster91/simaqadeer.com](https://github.com/camster91/simaqadeer.com).
Serves the built React app and exposes a single `POST /api/contact`
endpoint that the contact form posts to.

## What this adds over the static build

| Feature | Static build | This app |
| --- | --- | --- |
| Static file serving | ✅ any web host | ✅ via Express + SPA fallback |
| `POST /api/contact` form backend | ❌ (mailto: shim only) | ✅ Node/Express with validation |
| Mailto bridge when API is bypassed | ❌ | ✅ shim opens mailto on success |
| Health endpoint | ❌ | ✅ `GET /healthz` |
| Graceful shutdown | ❌ | ✅ SIGTERM/SIGINT |
| JSON-LD `Book` + `Person` schema | ❌ | ✅ |
| Image weight optimisations | ❌ | ✅ (webp hero/cover) |

## Local dev

```bash
npm install
npm start                # serves on :3000
npm run dev              # same, but with --watch reload
npm test                 # 14 smoke tests against the running server
```

## Docker

```bash
docker build -t simaqadeer-app:local .
docker run --rm -p 3000:3000 simaqadeer-app:local
# or
docker compose up --build
```

The image is built multi-stage: a `node:22-alpine` builder installs
production deps, then a slim runtime stage copies the dep tree + server
+ public/, runs as the unprivileged `node` user, exposes `/healthz` for
container healthchecks.

## Configuration

All via environment variables (all optional):

| Var | Default | Notes |
| --- | --- | --- |
| `PORT` | `3000` | HTTP port to bind |
| `STATIC_DIR` | `./public` | Where the built static files live |
| `CONTACT_EMAIL` | `simaqadeerAuthor@gmail.com` | Destination of the contact form mailto |

## API

### `POST /api/contact`

The contact form posts JSON:
```json
{ "name": "Jane", "email": "jane@example.com", "subject": "Hello", "message": "..." }
```

Server validates (length caps, email format, control-char strip), then
returns a `mailto:` URL the front-end opens:

```json
{ "success": true, "mailto": "mailto:simaqadeerAuthor@gmail.com?subject=..." }
```

Validation failures return `400` with `{ success: false, error: "..." }`.

The front-end (`index.html` shim) opens the returned `mailto` URL on
success so the user's mail client fires. The bundle still sees
`success: true` and renders its built-in "Thank you" state.

### `GET /healthz`

```json
{ "status": "ok", "uptime": 12.34 }
```

For container liveness probes.

## File layout

```
.
├── Dockerfile                # multi-stage build, node:22-alpine
├── docker-compose.yml        # local dev single service
├── .dockerignore             # strip node_modules, .git, etc.
├── package.json              # express only — no client build
├── server.js                 # Express app (static + /api/contact)
├── test/
│   └── smoke.js              # 20-test suite, node:assert
├── scripts/
│   └── deploy.sh             # cron-based auto-deploy on the VPS
└── public/                   # built static site (copied into image)
    ├── index.html            # entry, with mailto bridge shim
    ├── content.json          # all site copy + structured data
    ├── 404.html
    ├── favicon.svg
    ├── apple-touch-icon.png  # 180x180 PNG, iOS home-screen bookmark
    ├── humans.txt            # literary-site tradition
    ├── sitemap.xml
    ├── robots.txt
    ├── assets/               # React bundle, CSS, fonts
    └── images/               # book cover, portrait, hero, og-image
```

## SPA fallback rules

The Express server has a `GET *` catch-all that serves `index.html`
for browser page loads and `404 plain text` for everything else. The
distinction is important — without it, a request for `/favicon.ico`
or `/admin` from a CLI tool or security scanner would get a 200 with
the SPA HTML body, which lies about what's at that path.

The fallback fires when **both** are true:
- The request path has no file extension (so `/book` gets the SPA,
  but `/favicon.ico` does not)
- The `Accept` header explicitly contains `text/html` (so browsers
  get the SPA, but `Accept: */*` and missing-`Accept` requests
  from CLI tools and scanners get a clean 404)

A request with `Accept: text/html` to `/admin` still gets the SPA
— a user might be testing a typo or pasting a stale link. But the
no-`Accept` and `Accept: */*` paths return 404 plain text.

## Deploy

The repo is deployed via a cron-based auto-deploy hook
(`/etc/cron.d/simaqadeer-deploy`) running on the VPS via crond, polling
GitHub every 5 minutes. After pushing to main on GitHub, the next cron
tick (within 5 minutes) detects the new SHA, pulls, rebuilds the
Docker image, swaps the container, and verifies the new
`/healthz` returns OK.

Traefik (running in a Docker container on the VPS) is the edge reverse
proxy. Sima routes live in `/opt/traefik/dynamic/routers.yml` with the
`simaqadeer-csp` (CSP + HSTS + X-Frame-Options + X-Content-Type-Options
+ Referrer-Policy) and `simaqadeer-assets` (asset Cache-Control)
middlewares. The deploy script does NOT touch the Traefik config — the
Traefik dynamic config is managed by `/opt/vps/bin/render.py` from
`/opt/vps/manifest/sites.yaml`, separately.

To force an immediate deploy without waiting 5 minutes, SSH in
and run the script directly:

```bash
ssh hostinger '/root/simaqadeer-app/scripts/deploy.sh'
```

Or from the local Mac (if the `hostinger` SSH alias is configured):

```bash
npm run deploy
```
