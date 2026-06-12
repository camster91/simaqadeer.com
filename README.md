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
│   └── smoke.js              # 14-test suite, node:assert
└── public/                   # built static site (copied into image)
    ├── index.html            # entry, with mailto bridge shim
    ├── content.json          # all site copy + structured data
    ├── 404.html
    ├── favicon.svg
    ├── sitemap.xml
    ├── robots.txt
    ├── assets/               # React bundle, CSS, fonts
    └── images/               # book cover, portrait, hero, og-image
```
