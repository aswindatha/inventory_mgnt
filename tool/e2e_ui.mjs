// Full-app UI drive in a visible Chromium window. Flutter web renders to
// canvas, so interaction goes through the a11y semantics tree: every tappable
// shows up as flt-semantics[aria-label="..."] positioned over its widget, so
// real mouse clicks work. Text fields: click the field's semantics node, the
// hidden <input> gets focus, then keyboard.type fills it.
//
//   node tool/e2e_ui.mjs           (from repo root)
//   node tool/e2e_ui.mjs --slow    (slower pacing to watch along)
import { chromium } from 'playwright';
import { mkdirSync } from 'node:fs';

const SHOTS = 'tool/e2e_shots';
mkdirSync(SHOTS, { recursive: true });
const slow = process.argv.includes('--slow');
const wait = (ms) =>
  new Promise((r) => setTimeout(r, slow ? ms * 4 : ms));

const EMAIL = 'e2e-tester@example.com';
const PASS = 'E2E-Tester-Passw0rd!23';

const browser = await chromium.launch({ headless: false });
const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
page.on('console', (m) => {
  if (m.type() === 'error') console.log('  [console.error]', m.text());
});
page.on('pageerror', (e) => console.log('  [pageerror]', e.message));

let step = 0;
async function shot(name) {
  await page.screenshot({ path: `${SHOTS}/${String(step++).padStart(2, '0')}-${name}.png` });
  console.log(`shot: ${name}`);
}

// Flutter's semantics DOM is nested: parent nodes' textContent concatenates
// children, so "leaf-most" nodes (no descendant also matching) are the real
// targets. Exact match first, substring fallback.
async function leafBoxes(label) {
  return page.evaluate((lbl) => {
    const all = [...document.querySelectorAll('flt-semantics')];
    const text = (el) =>
      (el.getAttribute('aria-label') || el.textContent || '').trim();
    const hits = (exact) =>
      all.filter((el) => {
        const t = text(el);
        return exact ? t === lbl : t.includes(lbl);
      });
    for (const exact of [true, false]) {
      const h = hits(exact).filter(
        (el) =>
          !hits(exact).some((o) => o !== el && el.contains(o)),
      );
      if (h.length) {
        return h.map((el) => {
          const r = el.getBoundingClientRect();
          return { x: r.x, y: r.y, w: r.width, h: r.height };
        });
      }
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
    await new Promise((r) => setTimeout(r, 250));
  }
  if (!boxes.length) throw new Error(`tap target not found: "${label}"`);
  const box = boxes[which === 'last' ? boxes.length - 1 : 0];
  await page.mouse.click(box.x + box.w / 2, box.y + box.h / 2);
  await wait(400);
}

async function fillField(label, text) {
  // The field's real <input> carries the aria-label; clicking it lets
  // Flutter focus/move its editing input, then raw key events type.
  const input = page.getByLabel(label).first();
  await input.waitFor({ timeout: 15000 });
  await input.click();
  await wait(300);
  await page.keyboard.type(text, { delay: slow ? 60 : 20 });
  await wait(200);
}

async function expectText(label) {
  const boxes = await leafBoxes(label);
  if (!boxes.length) throw new Error(`expected text not found: "${label}"`);
  console.log(`  sees: "${label}"`);
}

// --------------------------------------------------------------------------
console.log('== load + enable a11y ==');
await page.goto('http://127.0.0.1:8080', { waitUntil: 'load' });
await page.waitForSelector('flutter-view', { timeout: 60000 });
await wait(2000);
await page.locator('flt-semantics-placeholder').evaluate((el) => el.click());
await wait(1000);
await shot('signin');

console.log('== sign in ==');
await fillField('Email', EMAIL);
await fillField('Password', PASS);
await tap('Sign in');
await wait(2500);
await shot('after-signin');

// Onboarding (fresh user) -> create a company. Wait for the screen to settle
// first so the card is really there (or really absent).
await wait(1500);
const onOnboarding = (await leafBoxes('Set up your workspace')).length > 0;
console.log('  onboarding visible:', onOnboarding);
if (onOnboarding) {
  console.log('== onboarding: create company ==');
  await shot('onboarding');
  await fillField('Company name', 'Acme Labs');
  await tap('Create company');
  await wait(2500);
}
await shot('home-inventories');

console.log('== inventory journey ==');
// create_company seeds 'Main Inventory' (0002_rls.sql) so home is never empty.
await tap('Main Inventory');
await wait(1200);
await shot('inventory-detail-empty');

await tap('Add component');
await wait(1000);
await shot('add-component-form');
await fillField('Manufacturer part number', 'LM358');
await fillField('Name', 'Dual op amp');
await fillField('Opening quantity', '50');
await page.keyboard.press('Escape'); // dismiss any keyboard overlay
// 'Add component' matches both the app-bar title and the submit button —
// the tappable one comes later in the semantics tree.
await tap('Add component', 'last');
await wait(2500);
await shot('component-detail');

// In-app back (AppBar back button) — page.goBack() would walk URL history,
// which re-matches the replaced add-component route. The leading icon sits at
// the AppBar's left edge; try its semantics label first, then raw coords.
async function tapBack() {
  const boxes = await leafBoxes('Back');
  if (boxes.length) {
    const b = boxes[0];
    await page.mouse.click(b.x + b.w / 2, b.y + b.h / 2);
  } else {
    await page.mouse.click(153, 27); // leading AppBar icon on wide layout
  }
  await wait(600);
}
await tapBack();
await shot('inventory-detail-with-component');
await tapBack();
await shot('home-after-component');

console.log('== projects ==');
await tap('Projects');
await wait(1200);
await shot('projects-empty');
await tap('Add project');
await wait(800);
await shot('project-sheet');
await fillField('Name', 'Line follower');
await tap('Create project');
await wait(1500);
await shot('projects-list');
await tap('Line follower');
await wait(1200);
await shot('project-detail');
// Detail screens have no nav rail — pop back to the shell first.
await tapBack();

console.log('== purchasing + team ==');
await tap('Purchasing');
await wait(1200);
await shot('purchasing');
await tap('Team');
await wait(1200);
await shot('team');

console.log('== mobile layout check ==');
await page.setViewportSize({ width: 420, height: 850 });
await wait(1000);
await shot('mobile-team');

console.log('== dark mode check ==');
await page.emulateMedia({ colorScheme: 'dark' });
await wait(1000);
await shot('dark-team');

console.log('DONE');
await browser.close();
