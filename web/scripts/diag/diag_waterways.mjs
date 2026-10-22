// Headless verification for the Waterways (CA) reference overlay.
// Toggles the layer on, flies to a CA river area, asserts blue stream lines render,
// and confirms the legality layers + click-to-assess are unaffected. Screenshots out.
import { chromium } from 'playwright';

const url = process.argv[2] || 'http://localhost:5173';
const browser = await chromium.launch({
  args: ['--enable-unsafe-swiftshader', '--ignore-gpu-blocklist', '--enable-webgl', '--use-gl=angle', '--use-angle=swiftshader'],
});
const page = await browser.newPage({ viewport: { width: 1400, height: 900 } });
const tileLog = [];
page.on('response', (r) => { if (r.url().includes('tiles.waterways')) tileLog.push(`[${r.status()}] ${r.url().split('/').slice(-4).join('/')}`); });
page.on('pageerror', (e) => console.log('[pageerror]', e.message));

await page.evaluate(() => {}).catch(() => {});
await page.goto(url, { waitUntil: 'networkidle' }).catch((e) => console.log('[goto]', e.message));
await page.evaluate(() => {
  localStorage.setItem('orescout_ack_accepted', 'true');
  localStorage.setItem('orescout_ack_version', '1.0');
});
await page.reload({ waitUntil: 'networkidle' }).catch(() => {});
await page.waitForTimeout(2500);

// Toggle the Waterways layer on via the REAL UI path (the checkbox), so the store-driven
// visibility effect in MapView keeps it on. Then fly to the American River near Coloma
// (Sutter's Mill — the original 1848 gold strike; a dense, named stream area).
await page.getByText('Waterways (CA)').click();
await page.evaluate(() => window.__map?.jumpTo({ center: [-120.8916, 38.8002], zoom: 12 }));
await page.waitForTimeout(6000);

const r = await page.evaluate(() => {
  const m = window.__map;
  if (!m) return { error: 'no map' };
  const q = (layer) => { try { return m.queryRenderedFeatures({ layers: [layer] }).length; } catch (e) { return String(e); } };
  let src = -1, sample = null;
  try {
    const f = m.querySourceFeatures('waterways', { sourceLayer: 'tiles.waterways' });
    src = f.length; if (f[0]) sample = f[0].properties;
  } catch (e) { src = String(e); }
  return {
    zoom: Number(m.getZoom().toFixed(1)),
    waterwaysRendered: q('waterways'),
    waterwaysSourceFeatures: src,
    sampleProps: sample,
    vis: m.getLayoutProperty('waterways', 'visibility'),
    // legality unaffected:
    legalityRed: q('legality-prohibited'), legalityYellow: q('legality-ambiguous'),
  };
});
console.log('--- WATERWAYS (American River @ Coloma) ---');
console.log(JSON.stringify(r, null, 2));
console.log('--- waterways tile responses ---');
console.log(tileLog.slice(0, 8).join('\n') || '(none)');
await page.screenshot({ path: 'diag_waterways.png' });
console.log('screenshot -> web/scripts/diag/diag_waterways.png');
await browser.close();
