import { chromium } from 'playwright';
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const browser = await chromium.launch({ headless: false });
const page = await browser.newPage();
page.on('console', (m) => console.log('  [console]', m.type(), m.text().slice(0, 300)));
page.on('pageerror', (e) => console.log('  [pageerror]', e.message.slice(0, 300)));
page.on('requestfailed', (r) => console.log('  [reqfail]', r.url(), r.failure()?.errorText));
await page.goto('http://127.0.0.1:8080', { waitUntil: 'domcontentloaded', timeout: 60000 });
for (let i = 0; i < 12; i++) {
  await wait(5000);
  const has = await page.evaluate(() => !!document.querySelector('flutter-view'));
  const scripts = await page.evaluate(() =>
    [...document.scripts].map((s) => s.src.split('/').pop()).filter(Boolean),
  );
  console.log(`t=${(i + 1) * 5}s flutter-view=${has} scripts=${scripts.join(',')}`);
  if (has) break;
}
await browser.close();
