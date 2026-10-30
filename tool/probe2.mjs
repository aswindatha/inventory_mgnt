import { chromium } from 'playwright';
const browser = await chromium.launch({ headless: false });
const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
await page.goto('http://127.0.0.1:8080', { waitUntil: 'load' });
await page.waitForSelector('flutter-view', { timeout: 60000 });
await new Promise((r) => setTimeout(r, 2000));
await page.locator('flt-semantics-placeholder').evaluate((el) => el.click());
await new Promise((r) => setTimeout(r, 800));

// sign in
await page.getByLabel('Email').click();
await page.keyboard.type('e2e-tester@example.com');
await page.getByLabel('Password').click();
await page.keyboard.type('E2E-Tester-Passw0rd!23');
await page.mouse.click(640, 505); // Sign in button
await new Promise((r) => setTimeout(r, 4000));

const dump = await page.evaluate(() => {
  const out = [];
  document.querySelectorAll('flt-semantics').forEach((el) => {
    const t = (el.getAttribute('aria-label') || el.textContent || '').trim();
    if (t) out.push(t.slice(0, 80));
  });
  return out;
});
console.log(JSON.stringify(dump, null, 0));
await browser.close();
