import { chromium } from 'playwright';
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const browser = await chromium.launch({ headless: false });
const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
await page.goto('http://127.0.0.1:8080', { waitUntil: 'domcontentloaded' });
await page.waitForSelector('flutter-view', { timeout: 120000 });
await wait(4000);
await page.locator('flt-semantics-placeholder').evaluate((el) => el.click());
await wait(1000);
await page.getByLabel('Email').first().click();
await page.keyboard.type('e2e.member.tester@gmail.com', { delay: 40 });
await page.getByLabel('Password').first().click();
await page.keyboard.type('E2E-Member-Passw0rd!45', { delay: 40 });
// click the sign-in button node
const boxes = await page.evaluate(() => {
  const all = [...document.querySelectorAll('flt-semantics')];
  const text = (el) => (el.getAttribute('aria-label') || el.textContent || '').trim();
  const h = all.filter((el) => text(el) === 'Sign in');
  const leaves = h.filter((el) => !h.some((o) => o !== el && el.contains(o)));
  return leaves.map((el) => { const r = el.getBoundingClientRect(); return { x: r.x, y: r.y, w: r.width, h: r.height }; });
});
if (boxes[0]) await page.mouse.click(boxes[0].x + boxes[0].w / 2, boxes[0].y + boxes[0].h / 2);
await wait(5000);
await page.screenshot({ path: 'tool/e2e_shots/member-onboarding-check.png' });
const texts = await page.evaluate(() =>
  [...document.querySelectorAll('flt-semantics')]
    .map((el) => (el.getAttribute('aria-label') || el.textContent || '').trim())
    .filter((t) => t && t.length < 200),
);
console.log(JSON.stringify(texts.filter((t) => t.includes('Signed in')), null, 1));
await browser.close();
