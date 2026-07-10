// Type-ahead geocode dropdown diag (decision #40). Run: node web/diag_geocode.mjs [url]
//  (a) typing a place name shows a multi-candidate dropdown
//  (b) selecting a place FLIES but does NOT assess (no verdict panel) — the intent rule
//  (c) typing coordinates shows a coordinate row; selecting it FLIES AND assesses (panel opens)
import { chromium } from 'playwright';

const url = process.argv[2] || 'http://localhost:5173';
const failures = [];
const check = (name, cond, detail = '') => {
  console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}${detail ? ` :: ${detail}` : ''}`);
  if (!cond) failures.push(name);
};

const browser = await chromium.launch({
  args: ['--enable-unsafe-swiftshader', '--ignore-gpu-blocklist', '--use-gl=angle', '--use-angle=swiftshader'],
});
const page = await browser.newPage({ viewport: { width: 1400, height: 900 } });
page.on('pageerror', (e) => console.log(`[pageerror] ${e.message}`));

try {
  await page.goto(url, { waitUntil: 'networkidle' });
  await page.evaluate(() => {
    localStorage.setItem('orescout_ack_accepted', 'true');
    localStorage.setItem('orescout_ack_version', '1.0');
  });
  await page.reload({ waitUntil: 'load' });
  await page.waitForTimeout(2500);

  const search = page.locator('.search input');

  // ---- (a) place name -> multi-candidate dropdown ----
  await search.click();
  await search.fill('Springfield');
  await page.waitForSelector('.geo-drop .geo-item', { timeout: 9000 });
  await page.waitForTimeout(400);
  const placeCount = await page.locator('.geo-item .geo-kind', { hasText: 'place' }).count();
  check('place search shows a multi-candidate dropdown', placeCount > 1, `candidates=${placeCount}`);

  // ---- (b) selecting a place flies but does NOT assess ----
  const before = await page.evaluate(() => window.__map.getCenter());
  await page.locator('.geo-item').first().click();
  await page.waitForTimeout(1600);
  const after = await page.evaluate(() => window.__map.getCenter());
  const moved = Math.abs(after.lng - before.lng) > 0.05 || Math.abs(after.lat - before.lat) > 0.05;
  check('selecting a place flew the map', moved, `Δlng=${(after.lng - before.lng).toFixed(2)}`);
  check('selecting a place did NOT open a verdict panel (intent rule)',
    (await page.locator('.panel.assessment').count()) === 0);
  check('shows a "click the map to check" hint', (await page.locator('.search-hint').count()) === 1,
    await page.locator('.search-hint').textContent().catch(() => ''));

  // ---- (c) coordinates -> coord row -> fly AND assess ----
  await search.click();
  await search.fill('38.7127, -117.0722');
  await page.waitForSelector('.geo-item .geo-kind:has-text("coordinates")', { timeout: 4000 });
  check('coordinates show a coordinate row', true);
  await page.locator('.geo-item').first().click();
  await page.waitForTimeout(2500);
  check('selecting coordinates opened the verdict panel (fly + assess)',
    (await page.locator('.panel.assessment').count()) === 1);
} finally {
  await browser.close();
}

console.log(failures.length === 0 ? 'ALL CHECKS PASSED' : `FAILED: ${failures.join(', ')}`);
process.exit(failures.length === 0 ? 0 : 1);
