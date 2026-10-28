# SpeedDial landing page

Static site in `public/`, deployed as an assets-only Cloudflare Worker
(`wrangler.jsonc`, no script).

```bash
cd site
wrangler deploy            # https://speeddial.sh (account pinned in wrangler.jsonc)
```

## Screenshots

`public/shots/` are the real app rendering invented data from
`packages/app/tool/showcase/main.dart` (a dressed-up `FakeDaemonClient`).

```bash
export PATH="$HOME/p/flutter-sdk/bin:$PATH"
(cd packages/app && flutter build web -t tool/showcase/main.dart -o /tmp/showcase)
(cd /tmp/showcase && python3 -m http.server 8898 &)
# tools/shoot.mjs needs playwright-core and a Playwright Chromium.
# Spec: name=WxH@scale?query?waitMs?clickX,clickY (query pairs joined by commas)
node site/tools/shoot.mjs http://127.0.0.1:8898 /tmp/shots \
  "run-dark=1440x900@2?theme=dark,session=sess-3?5000" \
  "run-light=1440x900@2?theme=light,session=sess-3?5000" \
  "done-dark=1440x900@2?theme=dark?5000" \
  "done-light=1440x900@2?theme=light?5000" \
  "phone-run=390x844@3?theme=dark,session=sess-3?5000" \
  "phone-rail=390x844@3?theme=dark,session=sess-3?5000?26,33"
for f in /tmp/shots/*.png; do magick "$f" -quality 82 "site/public/shots/$(basename "${f%.png}").webp"; done
```
