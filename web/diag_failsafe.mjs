// Fail-safe / freshness diag (IMP-04, IMP-09, IMP-10). Run: node web/diag_failsafe.mjs [url]
//   (a) hatch-sprite fail-safe: with the 'hatch' image removed, the YELLOW under-layer
//       `legality-ambiguous-base` still renders over a known-YELLOW area.
//   (b) catch-all `legality-unknown-verdict` layer exists (and renders nothing on clean data).
//   (c) left panel shows data vintage + the >48h stale-claims warning.
//   (d) snapshot view shows the drift-check-failure banner when the live re-check errors.
import { chromium } from 'playwright';

const url = process.argv[2] || 'http://localhost:5301';
const API = process.env.DIAG_API_BASE || 'http://localhost:5167/api/v1';
const KEY = process.env.DIAG_API_KEY || 'dev-local-key-change-me';
// Representative point of a large YELLOW polygon (NM State Trust Land) — verified via
// tiles.legality_polygons + /assessment (collectingStatus YELLOW).
const YELLOW = { lng: -106.26782, lat: 34.19398 };

const failures = [];
const check = (name, cond, detail = '') => {
  console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}${detail ? ` :: ${detail}` : ''}`);
  if (!cond) failures.push(name);
};

const apiFetch = (path, init) =>
  fetch(`${API}${path}`, {
    ...init,
    headers: { 'X-Api-Key': KEY, ...(init?.body ? { 'Content-Type': 'application/json' } : {}) },
  });

const browser = await chromium.launch({
  args: ['--enable-unsafe-swiftshader', '--ignore-gpu-blocklist', '--enable-webgl', '--use-gl=angle', '--use-angle=swiftshader'],
});
const page = await browser.newPage({ viewport: { width: 1400, height: 900 } });
page.on('pageerror', (e) => console.log(`[pageerror] ${e.message}`));

let pinId = null;
try {
  await page.goto(url, { waitUntil: 'networkidle' });
  await page.evaluate(() => {
    localStorage.setItem('orescout_ack_accepted', 'true');
    localStorage.setItem('orescout_ack_version', '1.0');
  });
  await page.reload({ waitUntil: 'networkidle' });
  await page.waitForTimeout(3000);

  // ---- (a) + (b): hatch fail-safe over a known YELLOW area ----
  await page.evaluate(({ lng, lat }) => window.__map?.jumpTo({ center: [lng, lat], zoom: 12 }), YELLOW);
  await page.waitForTimeout(6000);
  const layerState = await page.evaluate(() => {
    const m = window.__map;
    if (!m) return null;
    const count = (l) => { try { return m.queryRenderedFeatures({ layers: [l] }).length; } catch (e) { return String(e); } };
    const before = { hatch: count('legality-ambiguous'), base: count('legality-ambiguous-base') };
    try { m.removeImage('hatch'); } catch { /* already missing */ }
    return new Promise((resolve) => {
      m.once('idle', () => resolve({
        before,
        afterRemoveImage: {
          base: count('legality-ambiguous-base'),
          unknownLayerExists: !!m.getLayer('legality-unknown-verdict'),
          unknownRendered: count('legality-unknown-verdict'),
        },
      }));
      m.triggerRepaint();
    });
  });
  console.log('--- HATCH FAIL-SAFE (known YELLOW area, zoom 12) ---');
  console.log(JSON.stringify(layerState));
  check('yellow base layer renders normally', typeof layerState?.before.base === 'number' && layerState.before.base > 0, `base=${layerState?.before.base}`);
  check('yellow base layer still renders after removeImage(hatch)', typeof layerState?.afterRemoveImage.base === 'number' && layerState.afterRemoveImage.base > 0, `base=${layerState?.afterRemoveImage.base}`);
  check('catch-all legality-unknown-verdict layer exists', layerState?.afterRemoveImage.unknownLayerExists === true);
  check('catch-all renders nothing on clean data', layerState?.afterRemoveImage.unknownRendered === 0, `count=${layerState?.afterRemoveImage.unknownRendered}`);
  await page.screenshot({ path: '/tmp/orescout-failsafe-yellow.png' });

  // ---- (c) freshness block + stale-claims warning (claimsAsOf in dev DB is >48h old) ----
  const vintage = await page.evaluate(() => document.querySelector('.panel.left .vintage')?.textContent ?? null);
  console.log('--- LEFT-PANEL VINTAGE TEXT ---');
  console.log(JSON.stringify(vintage));
  check('land-data vintage line shown', !!vintage && vintage.includes('Land data:'), vintage ?? 'missing');
  check('claims-as-of line shown', !!vintage && vintage.includes('Claims data as of'));
  check('stale-claims warning shown (>48h)', !!vintage && vintage.includes('claims overlay may be stale'));
  await page.screenshot({ path: '/tmp/orescout-stale-claims.png' });

  // ---- (d) IMP-09: snapshot view + failed live re-check -> warning banner ----
  const created = await apiFetch('/pins', {
    method: 'POST',
    body: JSON.stringify({ lat: YELLOW.lat, lng: YELLOW.lng, title: 'diag-failsafe-pin' }),
  });
  check('diag pin created', created.ok, `status=${created.status}`);
  pinId = created.ok ? (await created.json()).id : null;

  // 'load' not 'networkidle': map tile retries keep the network busy indefinitely here.
  await page.reload({ waitUntil: 'load' });
  await page.waitForTimeout(3500);
  // Make the background live re-check fail (network error) before opening the pin.
  await page.route('**/api/v1/assessment*', (r) => r.abort());
  await page.click('.tabs button:has-text("My Pins")');
  await page.click('.pin-main:has-text("diag-failsafe-pin")');
  // React Query retries 3x (~1s/2s/4s backoff) before settling into error state.
  await page.waitForTimeout(12000);
  const banner = await page.evaluate(() => {
    const p = document.querySelector('.panel.assessment');
    return {
      panelHead: p?.querySelector('.panel-head strong')?.textContent ?? null,
      driftHeads: [...(p?.querySelectorAll('.drift-head') ?? [])].map((e) => e.textContent),
      verdict: p?.querySelector('.verdict-label')?.textContent ?? null,
    };
  });
  console.log('--- SNAPSHOT DRIFT-FAILURE BANNER ---');
  console.log(JSON.stringify(banner));
  check('snapshot view open', banner.panelHead === 'Saved location', String(banner.panelHead));
  check('snapshot verdict rendered from stored snapshot', banner.verdict != null, String(banner.verdict));
  check('drift-check-failure banner shown', banner.driftHeads.some((t) => t?.includes('Couldn’t re-check current status')), JSON.stringify(banner.driftHeads));
  await page.screenshot({ path: '/tmp/orescout-drift-failure.png' });
} finally {
  if (pinId) await apiFetch(`/pins/${pinId}`, { method: 'DELETE' }).catch(() => {});
  await browser.close();
}

console.log(failures.length === 0 ? 'ALL CHECKS PASSED' : `FAILED: ${failures.join(', ')}`);
process.exit(failures.length === 0 ? 0 : 1);
