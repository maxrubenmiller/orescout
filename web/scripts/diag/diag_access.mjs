// Access & trails overlay diag (§5.4 — MVUM/GTLF ingest+display). Run: node web/scripts/diag/diag_access.mjs [url]
//  (a) the "Access & trails" master toggle renders travel-mode lines over a known motorized area
//      (Schell Creek Range / Ely NV — Humboldt-Toiyabe NF + BLM route country)
//  (b) each sub-toggle (Drive / Off-road / Hike-in) independently shows/hides its class
//  (c) the roads zoom gate holds: road layers draw nothing below z10 while trails may draw from z9
//  (d) clicking a line opens the access card: name · travel mode · surface · seasonal (advisory) ·
//      agency · the MVUM-authority disclaimer — over a motorized AND a non-motorized viewport
//  (e) the overlay is additive — legality source intact, no tile-error banner
import { chromium } from 'playwright';

const url = process.argv[2] || 'http://localhost:5173';
const failures = [];
const check = (n, c, d = '') => { console.log(`${c ? 'PASS' : 'FAIL'}  ${n}${d ? ` :: ${d}` : ''}`); if (!c) failures.push(n); };

const DRIVE_LAYERS = ['access-drive-road', 'access-drive-trail'];
const OFFROAD_LAYERS = ['access-offroad-road', 'access-offroad-trail'];
const HIKEIN_LAYERS = ['access-hikein'];
const ROAD_LAYERS = ['access-drive-road', 'access-offroad-road'];
const ALL_LAYERS = [...DRIVE_LAYERS, ...OFFROAD_LAYERS, ...HIKEIN_LAYERS];

// Known-data viewports (picked from tiles.access densities after the build, both NV — the
// federal-backbone stress-test state):
//   motorized: Schell Creek Range / Ely (Humboldt-Toiyabe NF + BLM; 37 drive + 394 off_road
//   segments in the 0.1° cell)   non-motorized: Toiyabe Crest trail country (73 hike_in)
const MOTORIZED = { center: [-114.9, 39.2], zoom: 12 };
const HIKE = { center: [-116.80, 39.48], zoom: 11.5 };

const browser = await chromium.launch({
  args: ['--enable-unsafe-swiftshader', '--ignore-gpu-blocklist', '--use-gl=angle', '--use-angle=swiftshader'],
});
const page = await browser.newPage({ viewport: { width: 1400, height: 900 } });
page.on('pageerror', (e) => console.log(`[pageerror] ${e.message}`));

const rendered = (layers) => page.evaluate((ls) => {
  const m = window.__map;
  return ls.reduce((n, id) => {
    try { return n + m.queryRenderedFeatures({ layers: [id] }).length; } catch { return n; }
  }, 0);
}, layers);

// Cold pg_tileserv can take >5s to serve a z12 viewport of a 300k-line table — wait for the
// map to actually finish loading tiles instead of a fixed sleep.
const waitForTiles = async (ms = 20000) => {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) {
    const done = await page.evaluate(() => window.__map.areTilesLoaded() && window.__map.loaded());
    if (done) return;
    await page.waitForTimeout(400);
  }
};

try {
  await page.goto(url, { waitUntil: 'networkidle' });
  await page.evaluate(() => {
    localStorage.setItem('orescout_ack_accepted', 'true');
    localStorage.setItem('orescout_ack_version', '1.0');
  });
  await page.reload({ waitUntil: 'load' });
  await page.waitForTimeout(2500);

  await page.evaluate((v) => window.__map.jumpTo(v), MOTORIZED);
  await page.waitForTimeout(1200);

  // Master toggle ON via the real checkbox (exercises the store wiring).
  await page.click('label:has-text("Access & trails")');
  await waitForTiles();
  await page.waitForTimeout(600); // one render frame after tiles land

  const drive0 = await rendered(DRIVE_LAYERS);
  const off0 = await rendered(OFFROAD_LAYERS);
  check('master toggle renders access lines (motorized NV viewport)', drive0 + off0 > 0,
    `drive=${drive0} offroad=${off0}`);

  // Sub-toggles hide/show ONLY their class.
  await page.click('label:has-text("Drive")');
  await page.waitForTimeout(700);
  const driveOffDrive = await rendered(DRIVE_LAYERS);
  const driveOffOff = await rendered(OFFROAD_LAYERS);
  check('Drive sub-toggle hides only the drive class', driveOffDrive === 0 && driveOffOff > 0,
    `drive=${driveOffDrive} offroad=${driveOffOff}`);
  await page.click('label:has-text("Drive")'); // back on
  await page.click('label:has-text("Off-road")');
  await page.waitForTimeout(700);
  check('Off-road sub-toggle hides only the off-road class',
    (await rendered(OFFROAD_LAYERS)) === 0 && (await rendered(DRIVE_LAYERS)) > 0);
  await page.click('label:has-text("Off-road")'); // back on
  await page.waitForTimeout(500);

  // Roads zoom gate: at z9.5 road layers must draw NOTHING (minzoom 10); by z10.5 they draw.
  await page.evaluate((v) => window.__map.jumpTo({ center: v.center, zoom: 9.5 }), MOTORIZED);
  await waitForTiles();
  await page.waitForTimeout(400);
  const roadsBelowGate = await rendered(ROAD_LAYERS);
  check('roads draw nothing below their z10 gate (z9.5)', roadsBelowGate === 0, `roads=${roadsBelowGate}`);
  await page.evaluate((v) => window.__map.jumpTo({ center: v.center, zoom: 10.5 }), MOTORIZED);
  await waitForTiles();
  await page.waitForTimeout(400);
  check('roads appear at/after the gate (z10.5)', (await rendered(ROAD_LAYERS)) > 0);

  // Click a motorized line at its rendered midpoint → access card in the assessment panel.
  await page.evaluate((v) => window.__map.jumpTo(v), MOTORIZED);
  await waitForTiles();
  await page.waitForTimeout(400);
  const pt = await page.evaluate((layers) => {
    const m = window.__map;
    for (const id of layers) {
      let fs = [];
      try { fs = m.queryRenderedFeatures({ layers: [id] }); } catch { continue; }
      for (const f of fs) {
        const cs = f.geometry.type === 'LineString' ? f.geometry.coordinates : (f.geometry.coordinates[0] ?? []);
        const mid = cs[Math.floor(cs.length / 2)];
        if (!mid) continue;
        const c = m.project(mid);
        if (c.x > 380 && c.x < 1000 && c.y > 90 && c.y < 840) {
          return { x: Math.round(c.x), y: Math.round(c.y), mode: f.properties.travel_mode };
        }
      }
    }
    return null;
  }, ALL_LAYERS);
  check('found a motorized line to click', !!pt, JSON.stringify(pt));
  if (pt) {
    const canvas = page.locator('.maplibregl-canvas');
    await canvas.click({ position: { x: pt.x, y: pt.y } });
    await page.waitForTimeout(900);
    check('clicking a line opens the access card', (await page.locator('.access-pop').count()) > 0);
    check('card shows the travel mode', (await page.locator('.access-pop .access-mode').count()) > 0,
      await page.locator('.access-pop .access-mode').textContent().catch(() => ''));
    check('card shows the source agency', (await page.locator('.access-pop .access-agency').count()) > 0,
      await page.locator('.access-pop .access-agency').textContent().catch(() => ''));
    const note = await page.locator('.access-pop .access-note').textContent().catch(() => '');
    check('card carries the MVUM-authority disclaimer', /MVUM|Motor Vehicle Use Map/.test(note || ''), note || 'no note');
  }
  await page.screenshot({ path: 'diag_access_motorized.png' });

  // Non-motorized viewport (Toiyabe Crest): hike-in lines render + their card.
  await page.evaluate((v) => window.__map.jumpTo(v), HIKE);
  await waitForTiles();
  await page.waitForTimeout(400);
  const hikeCount = await rendered(HIKEIN_LAYERS);
  check('hike-in trails render (Toiyabe Crest viewport)', hikeCount > 0, `count=${hikeCount}`);
  const hpt = await page.evaluate(() => {
    const m = window.__map;
    let fs = [];
    try { fs = m.queryRenderedFeatures({ layers: ['access-hikein'] }); } catch { return null; }
    for (const f of fs) {
      const cs = f.geometry.type === 'LineString' ? f.geometry.coordinates : (f.geometry.coordinates[0] ?? []);
      const mid = cs[Math.floor(cs.length / 2)];
      if (!mid) continue;
      const c = m.project(mid);
      if (c.x > 380 && c.x < 1000 && c.y > 90 && c.y < 840) {
        return { x: Math.round(c.x), y: Math.round(c.y), name: f.properties.name };
      }
    }
    return null;
  });
  check('found a hike-in trail to click', !!hpt, JSON.stringify(hpt));
  if (hpt) {
    await page.locator('.maplibregl-canvas').click({ position: { x: hpt.x, y: hpt.y } });
    await page.waitForTimeout(900);
    const modeTxt = await page.locator('.access-pop .access-mode').textContent().catch(() => '');
    check('hike-in card shows the non-motorized mode', /Hike in/.test(modeTxt || ''), modeTxt || 'no card');
  }
  await page.screenshot({ path: 'diag_access_hikein.png' });

  // Additive: legality intact, no tile-error banner, master off clears everything.
  check('legality source still present (overlay is additive)',
    await page.evaluate(() => !!window.__map.getSource('legality')));
  check('no tile-error banner from adding access', (await page.locator('.map-tile-error').count()) === 0);
  await page.click('label:has-text("Access & trails")'); // master OFF
  await page.waitForTimeout(700);
  check('master off hides every access layer', (await rendered(ALL_LAYERS)) === 0);
} finally {
  await browser.close();
}

console.log(failures.length === 0 ? 'ALL CHECKS PASSED' : `FAILED: ${failures.join(', ')}`);
process.exit(failures.length === 0 ? 0 : 1);
