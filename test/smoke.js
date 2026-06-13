// Smoke test for the Sima Qadeer author site server.
//
// Runs against a server already listening on $TEST_PORT (default 3000).
// Exits 0 on success, non-zero on first failure. No test framework —
// just node:assert, because the server's surface is small enough.
//
// Coverage:
//   - GET  /                 → 200, HTML
//   - GET  /content.json     → 200, JSON with .site.title
//   - GET  /assets/index-*.js → 200, application/javascript
//   - GET  /images/hero-bg.webp → 200, image/webp
//   - GET  /sitemap.xml      → 200, application/xml (or text/xml)
//   - GET  /robots.txt       → 200
//   - GET  /favicon.svg      → 200, image/svg+xml
//   - GET  /healthz          → 200, JSON { status: "ok" }
//   - GET  /book/some/deep    → 200 (SPA fallback to index.html)
//   - GET  /favicon.ico       → 404, plain text (NOT the SPA HTML)
//   - GET  /admin (no Accept) → 404 (attacker probe, no Accept header)
//   - GET  /wp-admin (no Accept) → 404
//   - GET  /apple-touch-icon.png → 404
//   - GET  /admin (Accept: text/html) → 200 SPA fallback
//   - POST /api/contact (valid)        → 200, { success: true, mailto }
//   - POST /api/contact (no body)      → 400
//   - POST /api/contact (bad email)    → 400
//   - POST /api/contact (huge message) → 400
//   - POST /api/contact (control chars in subject) → 200, control chars stripped

const assert = require('node:assert/strict');
const http = require('node:http');

const PORT = parseInt(process.env.TEST_PORT, 10) || 3000;
const BASE = `http://127.0.0.1:${PORT}`;

let pass = 0;
let fail = 0;

function request(method, path, body, extraHeaders) {
  return new Promise((resolve, reject) => {
    const headers = { ...(extraHeaders || {}) };
    if (body && !headers['Content-Type'] && !headers['content-type']) {
      headers['Content-Type'] = 'application/json';
    }
    const opts = {
      method,
      host: '127.0.0.1',
      port: PORT,
      path,
      headers,
    };
    const req = http.request(opts, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => {
        const buf = Buffer.concat(chunks);
        resolve({
          status: res.statusCode,
          headers: res.headers,
          body: buf,
          text: buf.toString('utf8'),
          json: () => {
            try { return JSON.parse(buf.toString('utf8')); }
            catch (e) { return null; }
          },
        });
      });
    });
    req.on('error', reject);
    if (body) req.write(JSON.stringify(body));
    req.end();
  });
}

async function test(name, fn) {
  try {
    await fn();
    console.log(`  ok   ${name}`);
    pass++;
  } catch (e) {
    console.log(`  FAIL ${name}`);
    console.log(`       ${e.message}`);
    fail++;
  }
}

(async () => {
  console.log(`smoke: ${BASE}`);

  await test('GET /', async () => {
    const r = await request('GET', '/');
    assert.equal(r.status, 200);
    assert.match(r.headers['content-type'] || '', /text\/html/);
    assert.match(r.text, /<title>.*Brown Girls.*<\/title>/);
  });

  await test('GET /content.json', async () => {
    const r = await request('GET', '/content.json');
    assert.equal(r.status, 200);
    const j = r.json();
    assert.ok(j, 'content.json is valid JSON');
    assert.equal(j.site.title, 'Sima Qadeer | Brown Girls, Grown Up');
  });

  await test('GET /assets/index-*.js', async () => {
    // Read the index.html to find the actual hashed filename
    const home = await request('GET', '/');
    const m = home.text.match(/\.\/assets\/(index-[A-Za-z0-9_-]+\.js)/);
    assert.ok(m, 'hashed JS filename found in index.html');
    const r = await request('GET', `/assets/${m[1]}`);
    assert.equal(r.status, 200);
    assert.match(r.headers['content-type'] || '', /javascript/);
  });

  await test('GET /images/hero-bg.webp', async () => {
    const r = await request('GET', '/images/hero-bg.webp');
    assert.equal(r.status, 200);
    assert.match(r.headers['content-type'] || '', /image\/(png|webp)/);
  });

  await test('GET /sitemap.xml', async () => {
    const r = await request('GET', '/sitemap.xml');
    assert.equal(r.status, 200);
    assert.match(r.headers['content-type'] || '', /(application|text)\/xml/);
    assert.match(r.text, /<urlset/);
  });

  await test('GET /robots.txt', async () => {
    const r = await request('GET', '/robots.txt');
    assert.equal(r.status, 200);
    assert.match(r.text, /User-agent/);
  });

  await test('GET /favicon.svg', async () => {
    const r = await request('GET', '/favicon.svg');
    assert.equal(r.status, 200);
    assert.match(r.headers['content-type'] || '', /(image\/svg|image-svg)/);
    assert.match(r.text, /<svg/);
  });

  await test('GET /healthz', async () => {
    const r = await request('GET', '/healthz');
    assert.equal(r.status, 200);
    const j = r.json();
    assert.equal(j.status, 'ok');
    assert.ok(j.uptime >= 0);
  });

  await test('GET /nonexistent-route (SPA fallback)', async () => {
    const r = await request('GET', '/book/some/deep/path', null, { Accept: 'text/html' });
    assert.equal(r.status, 200);
    assert.match(r.text, /<title>.*Brown Girls.*<\/title>/);
  });

  await test('GET /favicon.ico (real 404, not SPA HTML)', async () => {
    // Browsers probe for /favicon.ico. Without one, they expect a 404,
    // not the SPA HTML pretending to be a favicon.
    const r = await request('GET', '/favicon.ico');
    assert.equal(r.status, 404);
    assert.ok(!/<!doctype/i.test(r.text), 'should not be HTML');
  });

  await test('GET /admin (real 404 with no Accept header)', async () => {
    // Attacker probe — no Accept header means it is not a browser page
    // load. Real 404, not the SPA HTML.
    const r = await request('GET', '/admin', null, {});
    assert.equal(r.status, 404);
  });

  await test('GET /wp-admin (real 404)', async () => {
    const r = await request('GET', '/wp-admin', null, {});
    assert.equal(r.status, 404);
  });

  await test('GET /humans.txt (real file, plain text)', async () => {
    const r = await request('GET', '/humans.txt');
    assert.equal(r.status, 200);
    assert.match(r.headers['content-type'] || '', /text\/plain/);
    assert.match(r.text, /Sima Qadeer/);
  });

  await test('GET /brand-override.css (book-cover color/font override)', async () => {
    // The brand-override.css is loaded after the bundle's CSS to
    // re-skin the page to match the book cover (warm coral-red +
    // pink + magenta). Without this, the built site uses the
    // bundle's hardcoded deep-plum palette.
    const r = await request('GET', '/brand-override.css');
    assert.equal(r.status, 200);
    assert.match(r.headers['content-type'] || '', /text\/css/);
    // Sanity: the override must redefine the ink color (deep plum
    // #2e1a47 is the bundle's default; the override uses a warm
    // cocoa #3A1F1A to harmonize with the book cover).
    assert.match(r.text, /#3A1F1A/i, 'override should define warm cocoa ink');
    assert.match(r.text, /#E94560/i, 'override should define warm pink primary');
    // It must include the right !important overrides to win the
    // cascade against the bundle.
    assert.match(r.text, /!important/, 'must use !important to beat bundle');
  });

  await test('GET / (links brand-override.css after the bundle stylesheet)', async () => {
    // The override must come AFTER the bundle's CSS to win the
    // cascade. If the order is wrong the override is silently no-op'd.
    const r = await request('GET', '/', null, { Accept: 'text/html' });
    const bundleIdx = r.text.indexOf('index-ZArAOkPi.css');
    const overrideIdx = r.text.indexOf('brand-override.css');
    assert.ok(bundleIdx > 0, 'bundle stylesheet not linked');
    assert.ok(overrideIdx > 0, 'brand-override.css not linked');
    assert.ok(overrideIdx > bundleIdx,
      `override (${overrideIdx}) must come after bundle (${bundleIdx})`);
  });

  await test('GET /apple-touch-icon.png (real 180x180 PNG)', async () => {
    // iOS Safari probes this on every visit. We now ship a real 180x180
    // PNG at this path, so it returns 200 with the right content-type
    // and a valid PNG signature. iOS uses this for the home-screen
    // bookmark.
    const r = await request('GET', '/apple-touch-icon.png');
    assert.equal(r.status, 200);
    assert.match(r.headers['content-type'] || '', /image\/png/);
    // PNG magic: 89 50 4E 47
    assert.equal(r.body[0], 0x89);
    assert.equal(r.body[1], 0x50);
    assert.equal(r.body[2], 0x4e);
    assert.equal(r.body[3], 0x47);
  });

  await test('GET /admin (SPA fallback when Accept: text/html)', async () => {
    // A browser (with Accept: text/html) hitting /admin still gets the
    // SPA — a user might be testing a typo. But the no-Accept path
    // returned 404 above.
    const r = await request('GET', '/admin', null, { Accept: 'text/html' });
    assert.equal(r.status, 200);
    assert.match(r.text, /<title>.*Brown Girls.*<\/title>/);
  });

  await test('POST /api/contact (valid)', async () => {
    const r = await request('POST', '/api/contact', {
      name: 'Test User',
      email: 'test@example.com',
      subject: 'Hello',
      message: 'A short message.',
    });
    assert.equal(r.status, 200);
    const j = r.json();
    assert.equal(j.success, true);
    assert.match(j.mailto, /^mailto:/);
    // Verify the mailto is correctly URL-encoded
    const url = new URL(j.mailto.replace(/^mailto:/, 'mailto:'));
    assert.equal(url.pathname, 'simaqadeerAuthor@gmail.com');
    assert.match(url.searchParams.get('subject'), /Website contact: Hello/);
    assert.match(url.searchParams.get('body'), /Name: Test User/);
  });

  await test('POST /api/contact (no body)', async () => {
    const r = await request('POST', '/api/contact', {});
    assert.equal(r.status, 400);
    const j = r.json();
    assert.equal(j.success, false);
    assert.match(j.error, /name/);
  });

  await test('POST /api/contact (bad email)', async () => {
    const r = await request('POST', '/api/contact', {
      name: 'A', email: 'not-an-email', subject: 'B', message: 'C',
    });
    assert.equal(r.status, 400);
  });

  await test('POST /api/contact (huge message)', async () => {
    const r = await request('POST', '/api/contact', {
      name: 'A', email: 'a@b.co', subject: 'B', message: 'x'.repeat(6000),
    });
    assert.equal(r.status, 400);
  });

  await test('POST /api/contact (control chars stripped)', async () => {
    const r = await request('POST', '/api/contact', {
      name: 'A', email: 'a@b.co',
      subject: 'evil\r\nsubject',
      message: 'line1\nline2',
    });
    assert.equal(r.status, 200);
    const j = r.json();
    const url = new URL(j.mailto.replace(/^mailto:/, 'mailto:'));
    const subj = url.searchParams.get('subject');
    assert.ok(!subj.includes('\r'));
    assert.ok(!subj.includes('\n'));
  });

  await test('GET / (JSON-LD Book/Person schema are correct)', async () => {
    // The JSON-LD hardcoded in index.html drives Google's rich results.
    // This test catches the kind of regression that was introduced in
    // commit 070070e (where the Indigo Offer URL silently reverted
    // to a 404). If a future commit changes any of these expected
    // values, the test fails and the deploy gets caught.
    const r = await request('GET', '/', null, { Accept: 'text/html' });
    assert.equal(r.status, 200);
    const m = r.text.match(/<script type="application\/ld\+json">([\s\S]+?)<\/script>/);
    assert.ok(m, 'JSON-LD script tag present');
    const data = JSON.parse(m[1]);
    assert.equal(data['@context'], 'https://schema.org');
    assert.ok(Array.isArray(data['@graph']));

    // The Book node: ISBN, author reference, three preorder offers.
    const book = data['@graph'].find((n) => n['@type'] === 'Book');
    assert.ok(book, 'Book node present');
    assert.equal(book.isbn, '9798899480324');
    assert.equal(book.numberOfPages, 272);
    assert.equal(book.datePublished, '2026-06-15');
    assert.deepEqual(book.author, { '@id': 'https://simaqadeer.ashbi.ca/#author' });
    assert.equal(book.offers.length, 3);

    // Each Offer: must be a real URL (200 or 404-on-indigo for the
    // search URL is acceptable; what we want to catch is the kind of
    // stale typo from earlier commits).
    const indigoOffer = book.offers.find((o) => o.seller && o.seller.name === 'Indigo');
    assert.ok(indigoOffer, 'Indigo offer present');
    assert.ok(!indigoOffer.url.includes('/brown-girls-grown-up-stories/'),
      `Indigo offer URL looks like the broken 404 pattern: ${indigoOffer.url}`);
    assert.ok(indigoOffer.url.startsWith('https://www.indigo.ca/'),
      `Indigo offer URL not on indigo.ca: ${indigoOffer.url}`);
    assert.equal(indigoOffer.availability, 'https://schema.org/PreOrder');

    // The Person node: sameAs for social, image URL on simaqadeer.ashbi.ca
    // (not the apex simaqadeer.com — that may or may not be live).
    const person = data['@graph'].find((n) => n['@type'] === 'Person');
    assert.ok(person, 'Person node present');
    assert.equal(person['@id'], 'https://simaqadeer.ashbi.ca/#author');
    assert.ok(Array.isArray(person.sameAs));
    assert.ok(person.sameAs.some((u) => u.includes('instagram.com')));
    assert.ok(person.sameAs.some((u) => u.includes('facebook.com')));
    assert.ok(person.image.startsWith('https://simaqadeer.ashbi.ca/'),
      `Person image not on apex: ${person.image}`);

    // The WebSite node: language declared as en-CA.
    const site = data['@graph'].find((n) => n['@type'] === 'WebSite');
    assert.ok(site, 'WebSite node present');
    assert.equal(site.inLanguage, 'en-CA');
  });

  await test('GET / (canonical + og:url both point at apex)', async () => {
    // The live URL is simaqadeer.ashbi.ca for now (apex simaqadeer.com
    // still resolves to the legacy Hostinger PHP placeholder until
    // Cam flips the NameCheap A record). All canonical + OG references
    // must match what users actually see in the address bar.
    const r = await request('GET', '/', null, { Accept: 'text/html' });
    assert.equal(r.status, 200);
    const canonical = r.text.match(/<link rel="canonical" href="([^"]+)"/);
    const ogUrl = r.text.match(/<meta property="og:url" content="([^"]+)"/);
    assert.ok(canonical, 'canonical link present');
    assert.ok(ogUrl, 'og:url meta present');
    assert.equal(canonical[1], 'https://simaqadeer.ashbi.ca');
    assert.equal(ogUrl[1], 'https://simaqadeer.ashbi.ca');
  });

  await test('GET / (og:image dims match the actual file)', async () => {
    // The og-image.jpg is regenerated at 1200x1200. The meta tags
    // must declare the same dimensions or social previews will
    // display the wrong aspect ratio.
    const r = await request('GET', '/', null, { Accept: 'text/html' });
    const width = parseInt(
      (r.text.match(/og:image:width" content="(\d+)"/) || [])[1] || '0', 10);
    const height = parseInt(
      (r.text.match(/og:image:height" content="(\d+)"/) || [])[1] || '0', 10);
    assert.ok(width > 0 && height > 0,
      `og:image dimensions missing or zero: ${width}x${height}`);

    // Sanity: 1200x1200. If the file changes, this should be
    // updated in the same commit.
    assert.equal(width, 1200, `expected og:image width 1200, got ${width}`);
    assert.equal(height, 1200, `expected og:image height 1200, got ${height}`);
  });

  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail === 0 ? 0 : 1);
})();
