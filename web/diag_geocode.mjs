// Type-ahead geocode dropdown diag (decision #40). Run: node web/diag_geocode.mjs [url]
//  (a) a place name shows multiple candidates, ALL region-limited to the 8 supported states
//  (b) the dropdown caps at ~5 rows and scrolls when there are more
//  (c) selecting a place FLIES but does NOT assess (no verdict panel) — the intent rule
//  (d) typing coordinates shows a coord row; selecting it FLIES AND assesses (panel opens)
import { chromium } from 'playwright';

const url = process.argv[2] || 'http://localhost:5173';
const SUPPORTED = /Nevada|California|Arizona|Colorado|Utah|New Mexico|Oregon|Idaho/;
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

  // ---- (a) place name -> multiple in-region candidates ----
  await search.click();
  await search.fill('Bear Creek');
  await page.waitForSelector('.geo-drop .geo-item', { timeout: 9000 });
  await page.waitForTimeout(400);
  const labels = await page.locator('.geo-item .geo-label').allTextContents();
  check('place search shows multiple candidates', labels.length > 1, `n=${labels.length}`);
  const bad = labels.find((l) => !SUPPORTED.test(l));
  check('every candidate is in a supported state (region filter)', !bad, bad ? `LEAK: ${bad}` : 'all in-region');

  // ---- (b) capped to ~5 rows + scrollable when there are more ----
  const box = await page.evaluate(() => {
    const e = document.querySelector('.geo-drop');
    return e ? { ch: e.clientHeight, sh: e.scrollHeight } : null;
  });
  check('dropdown capped to ~5 rows (height)', !!box && box.ch <= 190, `clientHeight=${box?.ch}`);
  check('dropdown scrolls when >5 results', !box || labels.length <= 5 || box.sh > box.ch + 5, `sh=${box?.sh} ch=${box?.ch}`);

  // ---- (c) selecting a place flies but does NOT assess ----
  const before = await page.evaluate(() => window.__map.getCenter());
  await page.locator('.geo-item').first().click();
  await page.waitForTimeout(1600);
  const after = await page.evaluate(() => window.__map.getCenter());
  const moved = Math.abs(after.lng - before.lng) > 0.02 || Math.abs(after.lat - before.lat) > 0.02;
  check('selecting a place flew the map', moved, `Δlng=${(after.lng - before.lng).toFixed(2)} Δlat=${(after.lat - before.lat).toFixed(2)}`);
  check('selecting a place did NOT open a verdict panel (intent rule)',
    (await page.locator('.panel.assessment').count()) === 0);
  check('shows a "click the map to check" hint', (await page.locator('.search-hint').count()) === 1,
    await page.locator('.search-hint').textContent().catch(() => ''));

  // ---- (d) coordinates -> coord row -> fly AND assess ----
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
