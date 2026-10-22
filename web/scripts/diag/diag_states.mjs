// Loading / empty / error states + ambiguity-clarity diag (TODO "Frontend follow-ups";
// frontend-polish pass). Codifies the states QA so it can't silently regress:
//  (a) assessment loading + error states render (route-intercepted)
//  (b) the two kinds of YELLOW read distinctly: KNOWN explainer vs UNKNOWN explainer (§4.1.1)
//  (c) save-form state is per-location: saving at B never leaks "✓ Saved" onto a revisited,
//      CACHED point A (react-query keeps Result mounted on cached revisits — the original bug)
//  (d) GPX-export failure and pin-delete failure show visible feedback (were silent)
// Creates and deletes its own test pin. Run: node web/scripts/diag/diag_states.mjs [url]  (default :5173)
import { chromium } from 'playwright';

const url = process.argv[2] || 'http://localhost:5173';
const failures = [];
const check = (n, c, d = '') => { console.log(`${c ? 'PASS' : 'FAIL'}  ${n}${d ? ` :: ${d}` : ''}`); if (!c) failures.push(n); };

const A = { lng: -117.0, lat: 39.5 };    // open BLM (cached revisit target)
const B = { lng: -116.8, lat: 39.6 };    // second point (save happens here)
const KNOWN = { lng: -109.71873, lat: 32.43743 };   // AZ state trust -> YELLOW/KNOWN
const UNKNOWN = { lng: -119.81379, lat: 39.52963 }; // urban Reno -> YELLOW/UNKNOWN
const PIN_TITLE = '__diag_states_pin__';

const browser = await chromium.launch({
  args: ['--enable-unsafe-swiftshader', '--ignore-gpu-blocklist', '--use-gl=angle', '--use-angle=swiftshader'],
});
const page = await browser.newPage({ viewport: { width: 1400, height: 900 } });
page.on('pageerror', (e) => console.log(`[pageerror] ${e.message}`));

const clickAt = async ({ lng, lat }, settle = 1800) => {
  await page.evaluate(([g, t]) => window.__map.jumpTo({ center: [g, t], zoom: 12 }), [lng, lat]);
  await page.waitForTimeout(700);
  const pt = await page.evaluate(([g, t]) => window.__map.project([g, t]), [lng, lat]);
  await page.mouse.click(pt.x, pt.y);
  await page.waitForTimeout(settle);
};
const panelText = () => page.evaluate(() => document.querySelector('.assessment .panel-body')?.textContent ?? '');

try {
  await page.goto(url, { waitUntil: 'networkidle' });
  await page.evaluate(() => {
    localStorage.setItem('orescout_ack_accepted', 'true');
    localStorage.setItem('orescout_ack_version', '1.0');
  });
  await page.reload({ waitUntil: 'load' });
  await page.waitForTimeout(2000);

  // ---- (a) loading + error states --------------------------------------------
  await page.route('**/api/v1/assessment*', async (r) => { await new Promise((s) => setTimeout(s, 1500)); r.continue(); });
  await clickAt(A, 400);
  check('loading state renders ("Assessing…")', (await panelText()).includes('Assessing'));
  await page.waitForTimeout(2500);
  await page.unroute('**/api/v1/assessment*');

  await page.route('**/api/v1/assessment*', (r) => r.fulfill({ status: 500, contentType: 'application/json', body: '{"error":{"code":"internal_error","message":"An unexpected error occurred."}}' }));
  await clickAt(UNKNOWN, 1500);
  check('error state renders ("Couldn’t assess")', (await panelText()).includes('Couldn’t assess this location'));
  await page.unroute('**/api/v1/assessment*');

  // ---- (b) the two kinds of YELLOW -------------------------------------------
  await clickAt(KNOWN);
  let t = await panelText();
  check('YELLOW/KNOWN label "Ambiguous"', t.includes('Ambiguous'));
  check('YELLOW/KNOWN explainer (recognized designation / agency policy)',
    t.includes('recognized designation with its own rules'), t.slice(0, 160));
  await clickAt(UNKNOWN);
  t = await panelText();
  check('YELLOW/UNKNOWN label "Possibly private"', t.includes('Possibly private'));
  check('YELLOW/UNKNOWN explainer (unmapped private / lean out)',
    t.includes('most often that means unmapped private land'), t.slice(0, 160));

  // ---- (c) save-form is per-location (the cached-revisit leak) -----------------
  await clickAt(A);            // A enters the query cache, form untouched
  await clickAt(B);            // save at B
  await page.click('.assessment button:has-text("Save this location")');
  await page.fill('.save-form input', PIN_TITLE);
  await page.click('.save-form button:has-text("Save")');
  await page.waitForTimeout(1200);
  check('save succeeds at B ("✓ Saved")', (await panelText()).includes('Saved to your pins'));
  await clickAt(A, 1200);      // cached revisit — Result stays mounted; key must reset the form
  t = await panelText();
  check('revisited cached point A shows the save BUTTON (no leaked "✓ Saved")',
    t.includes('Save this location') && !t.includes('Saved to your pins'), t.slice(0, 120));

  // ---- (d) export + delete failure feedback -----------------------------------
  await page.click('.panel.left button.tab:has-text("My Pins")');   // pin list lives on its tab
  await page.waitForTimeout(600);
  // .first(): a crashed prior run can leave a same-titled pin behind; the end-of-run cleanup
  // loop below deletes every match either way.
  const pinRow = page.locator('.pin-list li', { hasText: PIN_TITLE }).first();
  await pinRow.waitFor({ timeout: 10000 });
  await page.route('**/api/v1/pins/*/export*', (r) => r.fulfill({ status: 500, contentType: 'application/json', body: '{"error":{"code":"internal_error","message":"An unexpected error occurred."}}' }));
  await pinRow.locator('button:has-text("GPX")').click();
  await page.waitForTimeout(600);
  check('export failure shows a message', (await pinRow.textContent())?.includes('Export failed') ?? false);
  await page.unroute('**/api/v1/pins/*/export*');

  await page.route('**/api/v1/pins/*', (r) => r.request().method() === 'DELETE'
    ? r.fulfill({ status: 500, contentType: 'application/json', body: '{"error":{"code":"internal_error","message":"An unexpected error occurred."}}' })
    : r.continue());
  await pinRow.locator('button:has-text("Delete")').click();
  await page.waitForTimeout(800);
  check('delete failure shows a message', (await pinRow.textContent())?.includes('Delete failed') ?? false);
  await page.unroute('**/api/v1/pins/*');

  // real delete (cleanup, exercising the success path) — loop until every match is gone
  for (let i = 0; i < 5 && (await page.locator('.pin-list li', { hasText: PIN_TITLE }).count()) > 0; i++) {
    await page.locator('.pin-list li', { hasText: PIN_TITLE }).first().locator('button:has-text("Delete")').click();
    await page.waitForTimeout(1200);
  }
  check('delete succeeds (all test pins gone)', (await page.locator('.pin-list li', { hasText: PIN_TITLE }).count()) === 0);

  await page.screenshot({ path: '/tmp/diag_states_final.png' });
} catch (e) {
  console.log(`[diag error] ${e.message}`);
  failures.push('diag crashed');
} finally {
  await browser.close();
}

console.log(failures.length === 0 ? 'ALL CHECKS PASSED' : `FAILURES: ${failures.join(' | ')}`);
process.exit(failures.length === 0 ? 0 : 1);
