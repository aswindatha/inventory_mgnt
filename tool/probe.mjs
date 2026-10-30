import { chromium } from 'playwright';
const browser = await chromium.launch({ headless: false });
const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
await page.goto('http://127.0.0.1:8080', { waitUntil: 'load' });
await page.waitForSelector('flutter-view', { timeout: 60000 });
await new Promise((r) => setTimeout(r, 2000));
await page.locator('flt-semantics-placeholder').evaluate((el) => el.click());
await new Promise((r) => setTimeout(r, 1000));

const dump = await page.evaluate(() => {
  const out = [];
  document.querySelectorAll('flt-semantics').forEach((el) => {
    const r = el.getBoundingClientRect();
    out.push({
      tag: 'sem',
      label: el.getAttribute('aria-label'),
      role: el.getAttribute('role'),
      input: !!el.querySelector('input'),
      rect: [r.x | 0, r.y | 0, r.width | 0, r.height | 0].join(','),
    });
  });
  document.querySelectorAll('input, textarea').forEach((el) => {
    const r = el.getBoundingClientRect();
    out.push({
      tag: el.tagName,
      type: el.type,
      label: el.getAttribute('aria-label'),
      rect: [r.x | 0, r.y | 0, r.width | 0, r.height | 0].join(','),
    });
  });
  return out;
});
console.log(JSON.stringify(dump, null, 1));
await browser.close();
