// Prospecting-potential overlay diag (Tier B). Run: node web/diag_prospectivity.mjs [url]
// Modeled on web/diag_mrds.mjs. Asserts:
//  (a) toggling "Prospecting potential (gold)" renders High star symbols over Sierra gold country
//  (b) Moderate markers appear at z11 and do NOT render below z10
//  (c) clicking a marker opens the popup with the tier headline + the exact upstream-note and
//      pathfinder-why strings from config/prospectivity.json (config-driven, not hardcoded)
//  (d) a quiet control viewport renders ZERO prospectivity features (hide-below-Moderate is real)
//  (e) the overlay is additive — legality source intact, no tile-error banner
//  (f) /assessment at a marker coordinate is byte-identical with the layer ON vs OFF
//      (assessmentDate stripped) — the overlay never touches the verdict path
import { chromium } from 'playwright';
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const url = process.argv[2] || 'http://localhost:5173';
const API = 'http://localhost:5167/api/v1';
const API_KEY = 'dev-local-key-change-me';
const repoRoot = fileURLToPath(new URL('..', import.meta.url));
const failures = [];
const check = (n, c, d = '') => { console.log(`${c ? 'PASS' : 'FAIL'}  ${n}${d ? ` :: ${d}` : ''}`); if (!c) failures.push(n); };

// The strings the popup must render — read from the same config the frontend imports.
const cfg = JSON.parse(readFileSync(new URL('../config/prospectivity.json', import.meta.url), 'utf8'));
const gold = cfg.commodities.find((c) => c.key === 'gold');
const UPSTREAM = gold.strings.upstream_note;
const WHY = gold.strings.pathfinder_blurb;

// DB escape hatch: find the densest cluster for a tier if the default viewports come up empty.
const psql = (sql) => execFileSync('docker', ['compose', 'exec', '-T', 'postgres', 'psql',
  '-U', 'postgres', '-d', 'miningapp', '-tAq', '-c', sql], { cwd: repoRoot, encoding: 'utf8' }).trim();
const densest = (tier) => {
  try {
    const row = psql(`SELECT round(ST_X(geom)::numeric,1), round(ST_Y(geom)::numeric,1), count(*)
      FROM tiles.prospectivity WHERE tier='${tier}' GROUP BY 1,2 ORDER BY 3 DESC LIMIT 1`);
    if (!row) return null;
    const [lng, lat, n] = row.split('|').map(Number);
    return { lng, lat, n };
  } catch { return null; }
};
const bboxCount = (lng, lat, halfLng, halfLat) => {
  try {
    return Number(psql(`SELECT count(*) FROM tiles.prospectivity WHERE geom &&
      ST_MakeEnvelope(${lng - halfLng},${lat - halfLat},${lng + halfLng},${lat + halfLat},4326)`));
  } catch { return null; }
};

const HIGH_LAYERS = ['prospectivity-high-producer', 'prospectivity-high-chemistry'];
const ALL_LAYERS = [...HIGH_LAYERS, 'prospectivity-moderate',
  'prospectivity-high-fallback', 'prospectivity-moderate-fallback'];

const browser = await chromium.launch({
  args: ['--enable-unsafe-swiftshader', '--ignore-gpu-blocklist', '--use-gl=angle', '--use-angle=swiftshader'],
});
const page = await browser.newPage({ viewport: { width: 1400, height: 900 } });
page.on('pageerror', (e) => console.log(`[pageerror] ${e.message}`));

const countIn = (layers) => page.evaluate((ls) => {
  try {
    const present = ls.filter((l) => window.__map.getLayer(l));
    return window.__map.queryRenderedFeatures({ layers: present }).length;
  } catch (e) { return String(e); }
}, layers);
const jumpTo = async (lng, lat, zoom) => {
  await page.evaluate(([g, t, z]) => window.__map.jumpTo({ center: [g, t], zoom: z }), [lng, lat, zoom]);
  await page.waitForTimeout(4000); // let vector tiles load + render
};

try {
  await page.goto(url, { waitUntil: 'networkidle' });
  await page.evaluate(() => {
    localStorage.setItem('orescout_ack_accepted', 'true');
    localStorage.setItem('orescout_ack_version', '1.0');
  });
  await page.reload({ waitUntil: 'load' });
  await page.waitForTimeout(2500);
  // Wait for the map's 'load' event (headless swiftshader can take ~3-10s): the glyph images and
  // the deferred visibility apply both hang off it.
  for (let i = 0; i < 30; i++) {
    if (await page.evaluate(() => window.__map?._loaded).catch(() => false)) break;
    await page.waitForTimeout(1000);
  }
  check('map load fired + glyph images registered',
    await page.evaluate(() => ['prospect-star-filled', 'prospect-star-hollow', 'prospect-diamond']
      .every((i) => window.__map.hasImage(i))));

  // ---- (f) assessment with the layer OFF (default), before any toggling ----
  const strip = (o) => { const c = JSON.parse(o); delete c.assessmentDate; return JSON.stringify(c); };
  const fetchAssess = async () => {
    const r = await fetch(`${API}/assessment?lat=38.8002&lng=-120.8916`, { headers: { 'X-Api-Key': API_KEY } });
    return { status: r.status, body: await r.text() };
  };
  const offResp = await fetchAssess();

  // ---- (a) High stars over Sierra Mother Lode gold country ----
  // Toggle ON via the checkbox (exercises the store wiring).
  await page.click('label:has-text("Prospecting potential")');
  let viewport = 'Mother Lode [-120.7, 38.6] z9';
  await jumpTo(-120.7, 38.6, 9);
  let high = await countIn(HIGH_LAYERS);
  if (!(typeof high === 'number' && high > 0)) {
    viewport = 'Grass Valley [-120.92, 39.22] z9';
    await jumpTo(-120.92, 39.22, 9);
    high = await countIn(HIGH_LAYERS);
  }
  if (!(typeof high === 'number' && high > 0)) {
    const d = densest('High');
    if (d) {
      viewport = `DB densest High cluster [${d.lng}, ${d.lat}] z9 (${d.n} High rows in cell)`;
      await jumpTo(d.lng, d.lat, 9);
      high = await countIn(HIGH_LAYERS);
    }
  }
  check('High star symbols render over gold country at z9', typeof high === 'number' && high > 0,
    `count=${high} @ ${viewport}`);

  // ---- (b) Moderate zoom gate: hidden at z9 (<10), visible by z11 ----
  const modAt9 = await countIn(['prospectivity-moderate', 'prospectivity-moderate-fallback']);
  check('Moderate markers do NOT render below z10 (at z9)', modAt9 === 0, `count=${modAt9}`);
  const z11 = await page.evaluate(() => window.__map.getCenter());
  let modViewport = `[${z11.lng.toFixed(2)}, ${z11.lat.toFixed(2)}] z11`;
  await jumpTo(z11.lng, z11.lat, 11);
  let mod = await countIn(['prospectivity-moderate', 'prospectivity-moderate-fallback']);
  if (!(typeof mod === 'number' && mod > 0)) {
    const d = densest('Moderate');
    if (d) {
      modViewport = `DB densest Moderate cluster [${d.lng}, ${d.lat}] z11 (${d.n} rows in cell)`;
      await jumpTo(d.lng, d.lat, 11);
      mod = await countIn(['prospectivity-moderate', 'prospectivity-moderate-fallback']);
    }
  }
  check('Moderate markers render at z11', typeof mod === 'number' && mod > 0, `count=${mod} @ ${modViewport}`);
  await page.screenshot({ path: '/tmp/prospectivity_markers.png' });

  // ---- (e) additive: legality intact, no tile-error banner ----
  check('legality source still present (overlay is additive)',
    await page.evaluate(() => !!window.__map.getSource('legality')));
  check('legality layers still render',
    await page.evaluate(() => !!window.__map.getLayer('legality-prohibited') && !!window.__map.getLayer('legality-prohibited-lowzoom')));
  check('no tile-error banner from adding prospectivity', (await page.locator('.map-tile-error').count()) === 0);

  // ---- (c) click a marker CENTER (tolerance-box) -> popup with config strings ----
  const pickMarker = () => page.evaluate((ls) => {
    const present = ls.filter((l) => window.__map.getLayer(l));
    const fs = window.__map.queryRenderedFeatures({ layers: present });
    // Prefer a High star (chemistry-earned first — it exercises the extra popup line + glyph).
    const rank = (f) => (f.properties.tier === 'High' ? (f.properties.tier_basis === 'chemistry' ? 0 : 1) : 2);
    fs.sort((a, b) => rank(a) - rank(b));
    for (const f of fs) {
      const c = window.__map.project(f.geometry.coordinates);
      if (c.x > 380 && c.x < 1000 && c.y > 90 && c.y < 840) {
        return { x: Math.round(c.x), y: Math.round(c.y), tier: f.properties.tier, basis: f.properties.tier_basis ?? null };
      }
    }
    // Nothing in the clear-click area — hand back the best candidate's lngLat so the caller can
    // re-center on it (its projection then lands dead-center, inside the clear area).
    return fs.length ? { recenter: fs[0].geometry.coordinates } : null;
  }, ALL_LAYERS);
  let pt = await pickMarker();
  if (pt?.recenter) {
    await jumpTo(pt.recenter[0], pt.recenter[1], 11);
    pt = await pickMarker();
    if (pt?.recenter) pt = null;
  }
  check('found a prospectivity marker to interact with', !!pt, JSON.stringify(pt));
  if (pt) {
    const canvas = page.locator('.maplibregl-canvas'); // canvas-relative coords (dodges topbar offset)
    await canvas.hover({ position: { x: pt.x, y: pt.y } });
    await page.waitForTimeout(350);
    check('hovering a marker shows the highlight ring',
      (await page.evaluate(() => window.__map.queryRenderedFeatures({ layers: ['prospectivity-hover'] }).length)) > 0);
    await canvas.click({ position: { x: pt.x, y: pt.y } });
    await page.waitForTimeout(800);
    check('clicking a marker CENTER opens the prospectivity popup', (await page.locator('.prospect-pop').count()) > 0);
    const popText = await page.locator('.prospect-pop').textContent().catch(() => '') ?? '';
    const expectHead = pt.tier === 'High' ? 'High potential' : 'Moderate potential';
    check(`popup shows the tier headline ("${expectHead}")`, popText.includes(expectHead),
      popText.slice(0, 90));
    if (pt.basis === 'chemistry') {
      check('chemistry-earned popup carries the chemistry-earned suffix + config line',
        popText.includes('chemistry-earned') && popText.includes(gold.strings.chemistry_earned));
    }
    check('popup shows the anomaly line', / anomaly — p\d+ in its watershed/.test(popText));
    check('popup contains the EXACT upstream-note string from config', popText.includes(UPSTREAM));
    check('popup contains the EXACT pathfinder-why blurb from config', popText.includes(WHY));
    await page.screenshot({ path: '/tmp/prospectivity_popup.png' });
  }

  // ---- (d) quiet control viewport renders ZERO prospectivity features ----
  // Verify emptiness in the DB FIRST, over the full z10 viewport extent (a 1400x900 window at
  // z10 spans ~2.2 x 1.4 deg — CA "farmland" centers still catch Sierra-foothill markers at the
  // viewport edge, so the eastern-NM plains cell is the reliable geologically-quiet control).
  const controls = [[-121.9, 37.0], [-120.3, 36.2], [-104.0, 34.0]];
  let control = controls[controls.length - 1];
  for (const c of controls) {
    const n = bboxCount(c[0], c[1], 1.2, 0.8);
    if (n === 0 || n === null) { control = c; break; }
  }
  const dbControl = bboxCount(control[0], control[1], 1.2, 0.8);
  await jumpTo(control[0], control[1], 10);
  const quiet = await countIn(ALL_LAYERS);
  check('quiet control viewport renders ZERO prospectivity features',
    quiet === 0, `count=${quiet} @ [${control}] z10 (DB rows in viewport extent: ${dbControl})`);
  check('no tile-error banner at the control viewport', (await page.locator('.map-tile-error').count()) === 0);

  // ---- (f) assessment with the layer ON, then compare ----
  const onResp = await fetchAssess();
  check('assessment API returns 200 with layer on/off', offResp.status === 200 && onResp.status === 200,
    `off=${offResp.status} on=${onResp.status}`);
  if (offResp.status === 200 && onResp.status === 200) {
    check('assessment byte-identical with layer ON vs OFF (assessmentDate stripped)',
      strip(offResp.body) === strip(onResp.body));
  }
} finally {
  await browser.close();
}

console.log(failures.length === 0 ? 'ALL CHECKS PASSED' : `FAILED: ${failures.join(', ')}`);
process.exit(failures.length === 0 ? 0 : 1);
