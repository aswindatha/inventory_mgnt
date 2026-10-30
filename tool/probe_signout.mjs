import { chromium } from 'playwright';

const wait = (ms) => new Promise((r) => setTimeout(r, ms));

const browser = await chromium.launch({ headless: false });
const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
await page.goto('http://127.0.0.1:8080', { waitUntil: 'domcontentloaded' });
await page.waitForSelector('flutter-view', { timeout: 60000 });
await wait(3000);
await page.locator('flt-semantics-placeholder').evaluate((el) => el.click());
await wait(1000);

async function leafBoxes(label) {
  return page.evaluate((lbl) => {
    const all = [...document.querySelectorAll('flt-semantics')];
    const text = (el) => (el.getAttribute('aria-label') || el.textContent || '').trim();
    for (const exact of [true, false]) {
      const h = all.filter((el) => (exact ? text(el) === lbl : text(el).includes(lbl)));
      const leaves = h.filter((el) => !h.some((o) => o !== el && el.contains(o)));
      if (leaves.length)
        return leaves.map((el) => {
          const r = el.getBoundingClientRect();
          return { x: r.x, y: r.y, w: r.width, h: r.height };
        });
    }
    return [];
  }, label);
}
async function tap(label, which = 'first') {
  const deadline = Date.now() + 15000;
  let boxes = [];
  while (Date.now() < deadline) {
    boxes = await leafBoxes(label);
    if (boxes.length) break;
    await wait(300);
  }
  if (!boxes.length) throw new Error(`not found: ${label}`);
  const b = boxes[which === 'last' ? boxes.length - 1 : 0];
  await page.mouse.click(b.x + b.w / 2, b.y + b.h / 2);
  await wait(300);
}
async function fillField(label, text) {
  await page.getByLabel(label).first().click();
  await page.keyboard.type(text, { delay: 40 });
}
async function leaves() {
  return page.evaluate(() =>
    [...document.querySelectorAll('flt-semantics')]
      .map((el) => (el.getAttribute('aria-label') || el.textContent || '').trim())
      .filter((t) => t && t.length < 140),
  );
}

await fillField('Email', 'e2e-tester@example.com');
await fillField('Password', 'E2E-Tester-Passw0rd!23');
await tap('Sign in');
await wait(4000);
await tap('Team');
await wait(2000);
await tap('Sign out');
await wait(1200);
await tap('Sign out', 'last');
for (let i = 0; i < 15; i++) {
  await wait(2000);
  const t = await leaves();
  const state = t.some((x) => x.includes('Set up your workspace'))
    ? 'ONBOARDING'
    : t.some((x) => x === 'Sign in')
      ? 'SIGN-IN'
      : 'other';
  console.log(`t=${(i + 1) * 2}s -> ${state}`);
  if (state === 'SIGN-IN') break;
}
await browser.close();
