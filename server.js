// Sima Qadeer author site — Node/Express server.
//
// The front-end is a static built React app (camster91/simaqadeer.com). This
// server does two things:
//
//   1. Serves the static bundle from /public on every request, with
//      index.html as the SPA fallback (so deep links like /book work).
//   2. Exposes POST /api/contact, which the contact form calls. The server
//      validates the payload, builds a mailto: URL, and returns it as JSON.
//      The front-end opens that URL — no SMTP, no third-party, no DNS to
//      configure in the container.
//
// Configuration via env (all optional):
//   PORT              — HTTP port to listen on (default 3000)
//   CONTACT_EMAIL     — destination for the contact form (default:
//                       simaqadeerAuthor@gmail.com)
//   STATIC_DIR        — where the built static files live (default ./public)

const express = require('express');
const path = require('path');

const PORT = parseInt(process.env.PORT, 10) || 3000;
const CONTACT_EMAIL = process.env.CONTACT_EMAIL || 'simaqadeerAuthor@gmail.com';
const STATIC_DIR = process.env.STATIC_DIR || path.join(__dirname, 'public');

const app = express();
app.disable('x-powered-by');
app.use(express.json({ limit: '16kb' }));

// Health probe — used by docker-compose / k8s liveness checks.
app.get('/healthz', (_req, res) => {
  res.json({ status: 'ok', uptime: process.uptime() });
});

// Contact form handler.
//
// Expected JSON: { name, email, subject, message }
// Returns 200 with { success: true, mailto: "mailto:...?..." } on accept.
// Returns 400 with { success: false, error: "..." } on validation failure.
//
// We do NOT send the email from inside the container. The client opens the
// returned mailto: URL, which the user's mail client handles. This keeps the
// container dependency-free and avoids SMTP credentials in env vars.
app.post('/api/contact', (req, res) => {
  const body = req.body || {};
  // typeof guards before String(): `String([...])` and `String({x:1})` would
  // coerce to "f,u,c,k" / "[object Object]" and pass the length cap, getting
  // mailed verbatim. Also `body.name || ''` treats the string "0" as empty
  // (falsy) — a user named "0" would be rejected. typeof catches both.
  const field = (v) => (typeof v === 'string' ? v : '').trim();
  const name = field(body.name);
  const email = field(body.email);
  const subject = field(body.subject);
  const message = field(body.message);

  // Validation — keep it tight. The bundle's form has client-side required
  // attributes, but a malicious client can POST anything.
  const errors = [];
  if (name.length < 1 || name.length > 200) errors.push('name length');
  if (email.length < 3 || email.length > 320) errors.push('email length');
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) errors.push('email format');
  if (subject.length < 1 || subject.length > 200) errors.push('subject length');
  if (message.length < 1 || message.length > 5000) errors.push('message length');

  // Strip control characters that would break the mailto URL.
  const sanitise = (s) => s.replace(/[\r\n\t\0\x00-\x1f]/g, ' ').trim();

  if (errors.length) {
    return res.status(400).json({ success: false, error: errors.join(', ') });
  }

  // RFC 6068: the address part of a mailto: is NOT URL-encoded. Only the
  // query string (subject / body) is. encodeURIComponent on the address
  // would turn `@` into `%40` and break mail clients.
  const safeSubject = sanitise(subject);
  const safeBody = sanitise(message);
  const lines = [
    `Name: ${sanitise(name)}`,
    `Email: ${sanitise(email)}`,
    '',
    safeBody,
  ];

  const mailto =
    `mailto:${CONTACT_EMAIL}` +
    `?subject=${encodeURIComponent('Website contact: ' + safeSubject)}` +
    `&body=${encodeURIComponent(lines.join('\n'))}`;

  return res.json({ success: true, mailto });
});

// Static file serving. Express will look up files relative to STATIC_DIR;
// the SPA fallback (index.html) handles routes that don't match a real file.
app.use(express.static(STATIC_DIR, { extensions: ['html'], maxAge: '1h' }));

// SPA fallback — any GET that didn't match a static file gets index.html,
// BUT only when the request looks like a browser page load. Otherwise we'd
// return HTML for /favicon.ico, /apple-touch-icon.png, /.well-known/*,
// and any attacker probe like /admin or /wp-admin — every one of those
// would get a 200 with HTML body, which is wrong on multiple levels:
//
//   - Browsers probing for favicon.ico get HTML instead of a 404, then
//     ignore the response, but the next probe (chrome://net-export)
//     shows a confusing "200 but rendered as HTML" entry.
//   - iOS Safari probes /apple-touch-icon.png on every visit; returning
//     HTML there can break the home-screen bookmark in some iOS builds.
//   - Security researchers probing for /admin, /wp-admin, /phpmyadmin
//     get a 200 (positive signal "this server has a thing at that path")
//     when the answer should be 404 (no such resource).
//   - /.well-known/* paths have well-known RFC-defined behavior; serving
//     HTML for missing ones is at best noise and at worst breaks clients.
//
// Rule: serve the SPA only when:
//   (a) the request path has no file extension (so e.g. /book and /about
//       get the SPA, but /robots.txt and /favicon.ico don't), AND
//   (b) the Accept header explicitly asks for text/html (so browsers
//       hitting /book get the SPA, but CLI tools and security scanners
//       sending Accept: */* — which node:http adds by default — get a
//       real 404). An empty Accept header is also treated as a browser
//       page load, since real browsers always send one.
app.get('*', (req, res) => {
  const accept = String(req.headers.accept || '');
  const reqPath = req.path;
  const looksLikeFile = /\.[a-z0-9]{1,6}$/i.test(reqPath);

  // Browser page load: the Accept header explicitly asks for text/html.
  // (Real browsers always send Accept, so an empty/missing Accept means
  // a non-browser client that should get a clean 404.) Accept: */* is
  // "give me anything" — also not a request for the SPA.
  const wantsHtml = /\btext\/html\b/.test(accept);
  if (!looksLikeFile && wantsHtml) {
    return res.sendFile(path.join(STATIC_DIR, 'index.html'), (err) => {
      if (err) res.status(404).send('Not found');
    });
  }

  // Anything else: real 404. No HTML body, just a clean status.
  res.status(404).type('text/plain').send('Not found');
});

const server = app.listen(PORT, () => {
  // eslint-disable-next-line no-console
  console.log(`simaqadeer.com listening on :${PORT} (static: ${STATIC_DIR})`);
});

// Graceful shutdown — useful for `docker stop` so in-flight requests finish
// before the process exits. 10s cap matches the typical docker stop timeout.
function shutdown(signal) {
  // eslint-disable-next-line no-console
  console.log(`${signal} received, draining connections…`);
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(1), 10000).unref();
}
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
