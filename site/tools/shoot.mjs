import { chromium } from 'playwright-core';

// usage: node shoot.mjs <baseUrl> <outDir> name=w x h@scale?query [...]
const [base, out, ...shots] = process.argv.slice(2);
const browser = await chromium.launch({
  executablePath: `${process.env.HOME}/.cache/ms-playwright/chromium-1208/chrome-linux64/chrome`,
  args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader'],
});
for (const spec of shots) {
  const name = spec.slice(0, spec.indexOf('='));
  const rest = spec.slice(spec.indexOf('=') + 1);
  const [size, query = '', waitMs = '4000', click = ''] = rest.split('?');
  const [dims, scale = '2'] = size.split('@');
  const [w, h] = dims.split('x').map(Number);
  const page = await browser.newPage({
    viewport: { width: w, height: h },
    deviceScaleFactor: Number(scale),
  });
  page.on('console', (m) => {
    if (m.type() === 'error') console.log(`[${name}]`, m.text());
  });
  await page.goto(`${base}/?${query.replace(/,/g, '&')}`);
  await page.waitForTimeout(Number(waitMs));
  if (click) {
    const [x, y] = click.split(',').map(Number);
    await page.mouse.click(x, y);
    await page.waitForTimeout(1500);
  }
  await page.screenshot({ path: `${out}/${name}.png` });
  await page.close();
  console.log('shot', name);
}
await browser.close();
