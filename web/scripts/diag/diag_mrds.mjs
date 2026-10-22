// MRDS gold-overlay diag (Tier A). Run: node web/scripts/diag/diag_mrds.mjs [url]
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

  // Pick a gold dot with a full-record link in the CLEAR map area; use its projected CENTER (no
  // pixel-hunting) — the tolerance-box hit-test must make a center click land, like a real user.
  const pt = await page.evaluate(() => {
    const fs = window.__map.queryRenderedFeatures({ layers: ['mrds'] });
    for (const f of fs) {
      if (!f.properties.url) continue;
      const c = window.__map.project(f.geometry.coordinates);
      if (c.x > 380 && c.x < 1000 && c.y > 90 && c.y < 840) {
        return { x: Math.round(c.x), y: Math.round(c.y), name: f.properties.site_name };
      }
    }
    return null;
  });
  check('found a gold dot to interact with', !!pt, JSON.stringify(pt));
  if (pt) {
    const canvas = page.locator('.maplibregl-canvas'); // canvas-relative coords (dodges topbar offset)
    // hover → highlight ring + pointer cursor
    await canvas.hover({ position: { x: pt.x, y: pt.y } });
    await page.waitForTimeout(350);
    check('hovering a dot shows the highlight ring',
      (await page.evaluate(() => window.__map.queryRenderedFeatures({ layers: ['mrds-hover'] }).length)) > 0);
    // click the CENTER (no pixel-hunt) → popup must open thanks to the tolerance box
    await canvas.click({ position: { x: pt.x, y: pt.y } });
    await page.waitForTimeout(800);
    check('clicking a dot CENTER opens the MRDS popup', (await page.locator('.mrds-pop').count()) > 0);
    check('popup shows development status', (await page.locator('.mrds-pop .mrds-stat').count()) > 0,
      await page.locator('.mrds-pop strong').textContent().catch(() => ''));
    const href = await page.locator('.mrds-pop .mrds-link').getAttribute('href').catch(() => null);
    check('popup links to the full USGS record', /mrdata\.usgs\.gov|show-mrds/.test(href || ''), href || 'no link');
  }

  // ── Related-table ENRICHMENT (build_mrds.sql) — pin a stable famous site and assert the popup
  // shows a full commodity NAME (not the raw code) and an ore/gangue minerals line. Pinned:
  // dep_id 10086589 "Empire" (Sierra Co., CA; past producer) — Gold · ore Galena/Gold/Pyrite,
  // gangue Quartz, a.k.a. Gold Valley. Fly straight to it and click it by dep_id (no pixel-hunt).
  const PINNED = { dep_id: '10086589', lng: -120.70492, lat: 39.64905 };
  await page.evaluate((s) => window.__map.jumpTo({ center: [s.lng, s.lat], zoom: 13 }), PINNED);
  await page.waitForTimeout(3500);
  const pin = await page.evaluate((s) => {
    const fs = window.__map.queryRenderedFeatures({ layers: ['mrds'] });
    const f = fs.find((x) => String(x.properties.dep_id) === s.dep_id);
    if (!f) return null;
    const c = window.__map.project(f.geometry.coordinates);
    return { x: Math.round(c.x), y: Math.round(c.y), maj: f.properties.commodities_major,
             ore: f.properties.ore_minerals, gangue: f.properties.gangue_minerals };
  }, PINNED);
  check('pinned enriched site (Empire, dep_id 10086589) present in tiles', !!pin, JSON.stringify(pin));
  if (pin) {
    check('pinned site carries a full commodity name in the tile', /Gold/.test(pin.maj || ''), `major=${pin.maj}`);
    const canvas = page.locator('.maplibregl-canvas');
    await canvas.click({ position: { x: pin.x, y: pin.y } });
    await page.waitForTimeout(800);
    check('enriched popup opens for the pinned site', (await page.locator('.mrds-pop').count()) > 0);
    const majTxt = await page.locator('.mrds-pop .mrds-comm-major').textContent().catch(() => '');
    check('popup shows the full commodity name (not the raw code)', /Gold/.test(majTxt || ''), majTxt || 'no major line');
    check('popup shows an ore/gangue minerals line', (await page.locator('.mrds-pop .mrds-min').count()) > 0,
      await page.locator('.mrds-pop .mrds-min').textContent().catch(() => ''));
  }
} finally {
  await browser.close();
}

console.log(failures.length === 0 ? 'ALL CHECKS PASSED' : `FAILED: ${failures.join(', ')}`);
process.exit(failures.length === 0 ? 0 : 1);
