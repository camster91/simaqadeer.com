# simaqadeer.com

Static site for Sima Qadeer, author of *Brown Girls, Grown Up* (Curbstone Books / Northwestern University Press, June 2026).

## Stack

- Built with Vite + React + TypeScript + Tailwind
- No build step in the repo — this is the **built static output** ready for any static host
- Google Fonts: Playfair Display (display), Source Serif 4 (body), Caveat (handwritten), Space Grotesk (UI), IBM Plex Mono (mono)
- Self-hosted: NORD Light/Regular/Medium/Bold (`.otf`) under `/assets/fonts/` for subheadings
- Content: `content.json` (book info, events, press kit, contact, SEO)
- Press kit: 3 mailto request links to simaqadeerAuthor@gmail.com

## Deploy

Drop the repo on any static host:
- GitHub Pages — enable Pages on `main`, root
- Netlify / Vercel / Cloudflare Pages — drag the folder, done
- Custom domain — point `simaqadeer.com` A record at the host, set canonical in `index.html`

## Local preview

```
python3 -m http.server 8765
```

Then open http://127.0.0.1:8765/.

## Files of note

- `index.html` — entry point, font preloads, OG tags
- `content.json` — all site copy + structured data
- `assets/index-CzKR_26g.js` — bundled React app (hashed)
- `assets/index-ZArAOkPi.css` — bundled Tailwind CSS
- `assets/fonts/NORD-*.otf` — self-hosted NORD subheading font
- `images/` — book cover, author portrait, hero bg
- `404.html`, `robots.txt`, `sitemap.xml` — SEO + error page
