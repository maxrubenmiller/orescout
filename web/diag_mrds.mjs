// MRDS gold-overlay diag (Tier A). Run: node web/diag_mrds.mjs [url]
//  (a) toggling "Gold occurrences (MRDS)" renders gold points over CA gold country
//  (b) the overlay is additive — legality source intact, no tile-error banner
//  (c) clicking a gold point opens the reference popup with site name + status
import { chromium } from 'playwright';

const url = process.argv[2] || 'http://localhost:5173';
const failures = [];
const check = (n, c, d = '') => { console.log(`${c ? 'PASS' : 'FAIL'}  ${n}${d ? ` :: ${d}` : ''}`); if (!c) failures.push(n); };

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

  // Fly to CA gold country (Grass Valley / Sierra foothills).
  await page.evaluate(() => window.__map.jumpTo({ center: [-120.92, 39.22], zoom: 11 }));
  await page.waitForTimeout(1200);

  // Toggle the gold layer on via the checkbox (exercises the store wiring).
  await page.click('label:has-text("Gold occurrences")');
  await page.waitForTimeout(4500); // let vector tiles load + render

  const goldCount = await page.evaluate(() => {
    try { return window.__map.queryRenderedFeatures({ layers: ['mrds'] }).length; } catch (e) { return String(e); }
  });
  check('gold (MRDS) points render when toggled on', typeof goldCount === 'number' && goldCount > 0, `count=${goldCount}`);

  check('legality source still present (overlay is additive)',
    await page.evaluate(() => !!window.__map.getSource('legality')));
  check('no tile-error banner from adding MRDS', (await page.locator('.map-tile-error').count()) === 0);

  // Click a rendered gold point → reference popup. Pick a pixel in the CLEAR map area (avoid the
  // left panel ~320px + right panel) where a SINGLE-POINT query actually hits a dot — that's the
  // same hit-test maplibre's click delegation uses, so it guarantees the popup handler fires.
  const pt = await page.evaluate(() => {
    const fs = window.__map.queryRenderedFeatures({ layers: ['mrds'] });
    for (const f of fs) {
      if (!f.properties.url) continue; // pick one that has a full-record link (deterministic)
      const c = window.__map.project(f.geometry.coordinates);
      if (!(c.x > 360 && c.x < 1000 && c.y > 70 && c.y < 850)) continue;
      const cx = Math.round(c.x), cy = Math.round(c.y);
      // scan INTEGER pixels (playwright clicks integers) for one maplibre registers as on-feature
      for (let dy = -3; dy <= 3; dy++) for (let dx = -3; dx <= 3; dx++) {
        const x = cx + dx, y = cy + dy;
        if (window.__map.queryRenderedFeatures([x, y], { layers: ['mrds'] }).length) {
          return { x, y, name: f.properties.site_name, stat: f.properties.dev_stat };
        }
      }
    }
    return null;
  });
  check('found a gold point to click', !!pt, JSON.stringify(pt));
  if (pt) {
    // project() coords are CANVAS-relative; click via the canvas element so the topbar offset
    // (page.mouse uses viewport coords) doesn't shift the click off the dot.
    await page.locator('.maplibregl-canvas').click({ position: { x: pt.x, y: pt.y } });
    await page.waitForTimeout(900);
    check('clicking a gold point opens the MRDS popup', (await page.locator('.mrds-pop').count()) > 0);
    check('popup shows development status', (await page.locator('.mrds-pop .mrds-stat').count()) > 0,
      await page.locator('.mrds-pop strong').textContent().catch(() => ''));
    const href = await page.locator('.mrds-pop .mrds-link').getAttribute('href').catch(() => null);
    check('popup links to the full USGS record', /mrdata\.usgs\.gov|show-mrds/.test(href || ''), href || 'no link');
  }
} finally {
  await browser.close();
}

console.log(failures.length === 0 ? 'ALL CHECKS PASSED' : `FAILED: ${failures.join(', ')}`);
process.exit(failures.length === 0 ? 0 : 1);
