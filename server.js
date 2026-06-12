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
  const name = String(body.name || '').trim();
  const email = String(body.email || '').trim();
  const subject = String(body.subject || '').trim();
  const message = String(body.message || '').trim();

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

// SPA fallback — any GET that didn't match a static file gets index.html.
app.get('*', (_req, res) => {
  res.sendFile(path.join(STATIC_DIR, 'index.html'), (err) => {
    if (err) {
      // If the SPA fallback also fails (e.g. static dir missing), return 404
      // with a clear message rather than the default Express HTML page.
      res.status(404).send('Not found');
    }
  });
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
