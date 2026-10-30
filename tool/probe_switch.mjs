import { chromium } from 'playwright';
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const browser = await chromium.launch({ headless: false });
const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
await page.goto('http://127.0.0.1:8080', { waitUntil: 'domcontentloaded' });
await page.waitForSelector('flutter-view', { timeout: 120000 });
await wait(4000);
await page.locator('flt-semantics-placeholder').evaluate((el) => el.click());
await wait(1000);

async function leafBoxes(label) {
  return page.evaluate((lbl) => {
    const all = [...document.querySelectorAll('flt-semantics')];
    const text = (el) => (el.getAttribute('aria-label') || el.textContent || '').trim();
    for (const exact of [true, false]) {
      const h = all.filter((el) => (exact ? text(el) === lbl : text(el).includes(lbl)));
      const leaves = h.filter((el) => !h.some((o) => o !== el && el.contains(o)));
      const vis = leaves.filter((el) => { const r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0; });
      if (vis.length) return vis.map((el) => { const r = el.getBoundingClientRect(); return { x: r.x, y: r.y, w: r.width, h: r.height }; });
    }
    return [];
  }, label);
}
async function tap(label, which = 'first') {
  const deadline = Date.now() + 15000;
  let boxes = [];
  while (Date.now() < deadline) { boxes = await leafBoxes(label); if (boxes.length) break; await wait(300); }
  if (!boxes.length) throw new Error('not found: ' + label);
  const b = boxes[which === 'last' ? boxes.length - 1 : 0];
  await page.mouse.click(b.x + b.w / 2, b.y + b.h / 2);
  await wait(300);
}
async function fill(label, text) {
  await page.getByLabel(label).first().click();
  await wait(200);
  await page.keyboard.press('ControlOrMeta+A');
  await page.keyboard.type(text, { delay: 40 });
}
async function dump(tag) {
  const texts = await page.evaluate(() =>
    [...document.querySelectorAll('flt-semantics')]
      .filter((el) => { const r = el.getBoundingClientRect(); return r.width > 0; })
      .map((el) => (el.getAttribute('aria-label') || el.textContent || '').trim())
      .filter((t) => t && t.length < 140),
  );
  console.log(`--- ${tag}:`, JSON.stringify(texts.filter((t) => t.includes('Signed in') || t.includes('workspace') || t === 'Sign in')));
}

// owner has a company right now (previous partial run left it) -> sign in -> home
await fill('Email', 'e2e-tester@example.com');
await fill('Password', 'E2E-Tester-Passw0rd!23');
await tap('Sign in');
await wait(3500);
await dump('after owner sign-in');
await tap('Team');
await wait(1800);
await tap('Sign out');
await wait(900);
await tap('Sign out', 'last');
await wait(3000);
await dump('after owner sign-out');

await fill('Email', 'e2e.member.tester@gmail.com');
await fill('Password', 'E2E-Member-Passw0rd!45');
await tap('Sign in');
await wait(4000);
await dump('after member sign-in');
await page.screenshot({ path: 'tool/e2e_shots/switch-member.png' });
await browser.close();
