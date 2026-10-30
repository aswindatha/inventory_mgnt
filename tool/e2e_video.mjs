// Complete multi-user E2E pass, recorded as a single video.
//
//   python tool/run_sql.py supabase/tests/reset_e2e_multiuser.sql
//   node tool/e2e_video.mjs        (from repo root)
//
// Journey: UI sign-up -> email confirm (SQL stands in for the mail click) ->
// owner creates company -> inventory/component/stock/project/purchasing/team ->
// member joins via invite code -> both see the same data -> mobile + dark ->
// sign-out returns to sign-in.
//
// Output: tool/e2e_video/<hash>.webm — one file, whole journey.
import { chromium } from 'playwright';
import { execFileSync } from 'node:child_process';
import { mkdirSync } from 'node:fs';

// Same env var the other SQL helpers use. Export it before running:
//   $env:SUPABASE_DB_URL = 'postgresql://...'   (pwsh)
const DSN = process.env.SUPABASE_DB_URL;
if (!DSN) {
  console.error('SUPABASE_DB_URL is not set');
  process.exit(1);
}

function dbScalar(sql) {
  return execFileSync(
    'python',
    [
      '-c',
      `import psycopg,sys;print(psycopg.connect(${JSON.stringify(
        DSN,
      )}).execute(${JSON.stringify(sql)}).fetchone()[0])`,
    ],
    { encoding: 'utf8' },
  ).trim();
}

const VIDEO_DIR = 'tool/e2e_video';
const SHOTS = 'tool/e2e_shots';
mkdirSync(VIDEO_DIR, { recursive: true });
mkdirSync(SHOTS, { recursive: true });

const wait = (ms) => new Promise((r) => setTimeout(r, ms * 1.6));
const OWNER = { email: 'e2e-tester@example.com', pass: 'E2E-Tester-Passw0rd!23' };
// example.com is rejected by hosted Supabase ("email address is invalid") — use
// a deliverable-looking domain. The address never receives mail; the run
// confirms it server-side.
const MEMBER = { email: 'e2e.member.tester@gmail.com', pass: 'E2E-Member-Passw0rd!45', name: 'E2E Member' };

const browser = await chromium.launch({ headless: false });
const context = await browser.newContext({
  viewport: { width: 1280, height: 800 },
  recordVideo: { dir: VIDEO_DIR, size: { width: 1280, height: 800 } },
  // flutter_service_worker.js pins a stale main.dart.js between rebuilds —
  // block it so each run really exercises the freshly built bundle.
  serviceWorkers: 'block',
});
const page = await context.newPage();
page.on('pageerror', (e) => console.log('  [pageerror]', e.message));

let step = 0;
const shot = (n) =>
  page.screenshot({ path: `${SHOTS}/v-${String(step++).padStart(2, '0')}-${n}.png` });

// ---- semantics helpers -----------------------------------------------------
async function leafNodes(label) {
  return page.evaluate((lbl) => {
    const all = [...document.querySelectorAll('flt-semantics')];
    const text = (el) =>
      (el.getAttribute('aria-label') || el.textContent || '').trim();
    for (const exact of [true, false]) {
      const h = all.filter((el) => {
        const t = text(el);
        return exact ? t === lbl : t.includes(lbl);
      });
      const leaves = h.filter((el) => !h.some((o) => o !== el && el.contains(o)));
      // Stale a11y subtrees linger in the DOM after navigation — only count
      // nodes that actually occupy space.
      const visible = leaves.filter((el) => {
        const r = el.getBoundingClientRect();
        return r.width > 0 && r.height > 0;
      });
      if (visible.length) {
        return visible.map((el) => {
          const r = el.getBoundingClientRect();
          return { x: r.x, y: r.y, w: r.width, h: r.height, t: text(el) };
        });
      }
    }
    return [];
  }, label);
}

async function leafTexts() {
  return page.evaluate(() =>
    [...document.querySelectorAll('flt-semantics')]
      .filter((el) => {
        const r = el.getBoundingClientRect();
        return r.width > 0 && r.height > 0;
      })
      .map((el) => (el.getAttribute('aria-label') || el.textContent || '').trim())
      .filter(Boolean),
  );
}

async function tap(label, which = 'first') {
  const deadline = Date.now() + 20000;
  let boxes = [];
  while (Date.now() < deadline) {
    boxes = await leafNodes(label);
    if (boxes.length) break;
    await new Promise((r) => setTimeout(r, 300));
  }
  if (!boxes.length) throw new Error(`tap target not found: "${label}"`);
  const b = boxes[which === 'last' ? boxes.length - 1 : 0];
  await page.mouse.click(b.x + b.w / 2, b.y + b.h / 2);
  await wait(400);
}

async function fillField(label, text) {
  const input = page.getByLabel(label).first();
  await input.waitFor({ timeout: 15000 });
  await input.click();
  await wait(250);
  // Re-select everything first: fields keep their value across sign-in cycles.
  await page.keyboard.press('ControlOrMeta+A');
  await page.keyboard.type(text, { delay: 50 });
  await wait(250);
}

async function check(label) {
  const deadline = Date.now() + 20000;
  while (Date.now() < deadline) {
    if ((await leafNodes(label)).length) {
      console.log(`  PASS  "${label}"`);
      return;
    }
    await new Promise((r) => setTimeout(r, 300));
  }
  const texts = await leafTexts();
  console.log(
    '  visible leaves:',
    JSON.stringify(texts.filter((t) => t.length < 120).slice(0, 60)),
  );
  throw new Error(`assertion failed: "${label}" not visible`);
}

async function tapBack() {
  const boxes = await leafNodes('Back');
  if (boxes.length) {
    const b = boxes[0];
    await page.mouse.click(b.x + b.w / 2, b.y + b.h / 2);
  } else {
    await page.mouse.click(153, 27);
  }
  await wait(700);
}

async function signIn({ email, pass }) {
  await check('Sign in');
  await fillField('Email', email);
  await fillField('Password', pass);
  await tap('Sign in');
  await wait(2800);
}

async function signOut() {
  await tap('Sign out');
  await wait(900);
  await tap('Sign out', 'last'); // dialog confirm
  await wait(2600);
  await check('Sign in'); // must land on sign-in, not onboarding
}

// ---------------------------------------------------------------------------
try {
  // ---- Phase 1: owner journey ------------------------------------------------
  console.log('STEP  load + owner sign-in');
  await page.goto('http://127.0.0.1:8080', {
    waitUntil: 'domcontentloaded',
    timeout: 60000,
  });
  await page.waitForSelector('flutter-view', { timeout: 120000 });
  await wait(4000);
  await page.locator('flt-semantics-placeholder').evaluate((el) => el.click());
  await wait(900);
  await shot('signin');
  await signIn(OWNER);
  await check('Set up your workspace');
  await shot('onboarding');
  await fillField('Company name', 'Acme Labs');
  await tap('Create company');
  await wait(2600);
  await check('Main Inventory');
  await shot('home');

  console.log('STEP  inventory -> add component');
  await tap('Main Inventory');
  await wait(1400);
  await check('No components yet');
  await tap('Add component');
  await wait(1100);
  await fillField('Manufacturer part number', 'LM358');
  await fillField('Name', 'Dual op amp');
  await page.keyboard.press('Escape');
  await fillField('Opening quantity', '50');
  await page.keyboard.press('Escape');
  await tap('Add component', 'last');
  await wait(2600);
  await check('Dual op amp');
  await check('Vendor pricing');
  await shot('component-detail');

  console.log('STEP  stock adjust via sheet');
  await tap('Custom');
  await wait(1000);
  await check('Adjust stock');
  await shot('adjust-sheet');
  await fillField('Quantity', '2');
  await tap('Apply adjustment');
  await wait(1600);
  await check('52');
  await check('Added 2');
  await shot('stock-adjusted');

  await tapBack();
  await check('Dual op amp');
  await shot('inventory-list');
  await tapBack();
  await wait(600);

  console.log('STEP  project -> add component line');
  await tap('Projects');
  await wait(1200);
  await tap('Add project');
  await wait(900);
  await shot('project-sheet');
  await fillField('Name', 'Line follower');
  await tap('Create project');
  await wait(1800);
  await check('Line follower');
  await tap('Line follower');
  await wait(1400);
  await check('No components yet');
  await shot('project-detail');
  await tap('Add component');
  await wait(1400);
  await tap('Dual op amp');
  await wait(1000);
  await shot('project-add-line');
  await fillField('Quantity required', '10');
  await tap('Add to project');
  await wait(1800);
  await check('Dual op amp');
  await check('Readiness');
  await shot('project-with-line');
  await tapBack();
  await wait(700);

  console.log('STEP  purchasing tab');
  await tap('Purchasing');
  await wait(1200);
  await check('Nothing queued');
  await shot('purchasing');

  console.log('STEP  team tab -> capture invite code');
  await tap('Team');
  await wait(1800);
  await check('Members (1)');
  await check('E2E Tester');
  await check('Owner');
  await shot('team-owner');
  // The invite code is a SelectableText — it never reaches the semantics tree
  // as a label, so read it from the database the run just populated.
  const inviteCode = dbScalar('select invite_code from public.companies');
  console.log(`  invite code: ${inviteCode}`);

  console.log('STEP  owner sign out');
  await signOut();
  await shot('signed-out');

  // ---- Phase 3: member joins with the invite code ----------------------------
  console.log('STEP  member sign-in -> join company by invite');
  await signIn(MEMBER);
  await check('Set up your workspace');
  await check('Signed in as E2E Member');
  await shot('member-onboarding');
  await fillField('Invite code', inviteCode);
  await tap('Join company');
  await wait(2600);
  await check('Main Inventory'); // same company data — the multi-user proof
  await shot('member-home');

  console.log('STEP  member sees shared inventory');
  await tap('Main Inventory');
  await wait(1400);
  await check('Dual op amp');
  await check('52');
  await shot('member-inventory');
  await tapBack();
  await wait(700);

  console.log('STEP  member team view');
  await tap('Team');
  await wait(1600);
  await check('Members (2)');
  await check('E2E Tester');
  await check('E2E Member');
  await check('e2e.member.tester@gmail.com');
  await shot('member-team');

  console.log('STEP  member sign out');
  await signOut();

  // ---- Phase 4: owner verifies the member, mobile + dark ----------------------
  console.log('STEP  owner re-sign-in -> sees the member');
  await signIn(OWNER);
  await check('Main Inventory');
  await tap('Team');
  await wait(1600);
  await check('Members (2)');
  await check('E2E Member');
  await shot('team-two-members');

  console.log('STEP  mobile layout');
  await page.setViewportSize({ width: 420, height: 850 });
  await wait(1200);
  await check('Members');
  await shot('mobile-team');

  console.log('STEP  dark mode');
  await page.emulateMedia({ colorScheme: 'dark' });
  await wait(1200);
  await shot('dark-team');

  console.log('STEP  final sign out');
  await page.emulateMedia({ colorScheme: 'light' });
  await page.setViewportSize({ width: 1280, height: 800 });
  await wait(800);
  await signOut();
  await shot('final-signin');

  console.log('ALL STEPS PASSED');
} finally {
  await context.close();
  await browser.close();
  console.log('video saved under tool/e2e_video/');
}
