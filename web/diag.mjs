import { chromium } from 'playwright';

const url = process.argv[2] || 'http://localhost:5173';
const browser = await chromium.launch({
  args: ['--enable-unsafe-swiftshader', '--ignore-gpu-blocklist', '--enable-webgl', '--use-gl=angle', '--use-angle=swiftshader'],
});
const page = await browser.newPage({ viewport: { width: 1400, height: 900 } });

const logs = [];
page.on('console', (m) => logs.push(`[${m.type()}] ${m.text()}`));
page.on('pageerror', (e) => logs.push(`[pageerror] ${e.message}\n${e.stack ?? ''}`));
page.on('requestfailed', (r) => logs.push(`[requestfailed] ${r.url()} :: ${r.failure()?.errorText}`));
const tileLog = [];
page.on('response', (r) => {
  const u = r.url();
  if (u.includes('legality_polygons') || u.includes('us-states') || u.includes('7800')) {
    tileLog.push(`[${r.status()}] ${u}`);
  }
});

await page.goto(url, { waitUntil: 'networkidle' }).catch((e) => logs.push(`[goto] ${e.message}`));
await page.waitForTimeout(2500);

const chain = await page.evaluate(() => {
  const h = (sel) => { const e = document.querySelector(sel); return e ? `${e.clientHeight}` : 'missing'; };
  return {
    html: document.documentElement.clientHeight,
    body: document.body.clientHeight,
    root: h('#root'), app: h('.app'), stage: h('.stage'), mapRoot: h('.map-root'),
    appDisplay: getComputedStyle(document.querySelector('.app')).display,
    rootHeightCss: getComputedStyle(document.querySelector('#root')).height,
  };
});
console.log('--- HEIGHT CHAIN ---');
console.log(JSON.stringify(chain, null, 2));

const info = await page.evaluate(() => {
  const el = document.querySelector('.map-root');
  const canvas = document.querySelector('.maplibregl-canvas');
  return {
    mapRootExists: !!el,
    mapRootSize: el ? { w: el.clientWidth, h: el.clientHeight } : null,
    canvasExists: !!canvas,
    canvasSize: canvas ? { w: canvas.clientWidth, h: canvas.clientHeight } : null,
    hasControls: !!document.querySelector('.maplibregl-control-container'),
  };
});

console.log('--- DIAG ---');
console.log(JSON.stringify(info, null, 2));
// Accept the ack modal, fly to NV, let overlays load, screenshot.
await page.evaluate(() => {
  localStorage.setItem('orescout_ack_accepted', 'true');
  localStorage.setItem('orescout_ack_version', '1.0');
});
await page.reload({ waitUntil: 'networkidle' }).catch(() => {});
await page.waitForTimeout(3000);

// Fly to Great Basin NP (a known RED area) and let the legality tiles load.
await page.evaluate(() => (window).__map?.jumpTo({ center: [-114.30, 39.0], zoom: 10 }));
await page.waitForTimeout(6000);
const features = await page.evaluate(() => {
  const m = (window).__map;
  if (!m) return null;
  const qr = (layer) => { try { return m.queryRenderedFeatures({ layers: [layer] }).length; } catch (e) { return String(e); } };
  let src = -1; let sampleProps = null;
  try {
    const f = m.querySourceFeatures('legality', { sourceLayer: 'legality_polygons' });
    src = f.length;
    if (f[0]) sampleProps = f[0].properties;
  } catch (e) { src = String(e); }
  return {
    zoom: m.getZoom(), red: qr('legality-prohibited'), yellow: qr('legality-ambiguous'),
    sourceFeatures: src, sampleProps,
    visRed: m.getLayoutProperty('legality-prohibited', 'visibility'),
  };
});
console.log('--- RENDERED LEGALITY FEATURES (near Great Basin NP) ---');
console.log(JSON.stringify(features));
console.log('--- TILE/ASSET RESPONSES ---');
console.log([...new Set(tileLog)].slice(0, 12).join('\n') || '(no tile requests seen)');
await page.screenshot({ path: '/tmp/orescout-map.png' });
console.log('--- screenshot saved ---');

// Click-to-assess: click the map center (over Great Basin NP = RED), check the panel.
await page.mouse.click(900, 450);
await page.waitForTimeout(2500);
const panel = await page.evaluate(() => {
  const p = document.querySelector('.panel.assessment');
  if (!p) return 'no panel';
  const v = p.querySelector('.verdict-label')?.textContent;
  const reason = p.querySelector('.reason')?.textContent;
  return { verdict: v, reason: reason?.slice(0, 60) };
});
console.log('--- CLICK-TO-ASSESS ---');
console.log(JSON.stringify(panel));
await page.screenshot({ path: '/tmp/orescout-assess.png' });
console.log('--- CONSOLE / ERRORS (last 8) ---');
console.log(logs.slice(-8).join('\n') || '(none)');
await browser.close();
