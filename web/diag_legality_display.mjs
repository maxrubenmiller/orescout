// Visual check for UI_CHANGES.md Changes 1+2 (legality display partition).
// Screenshots a mixed-verdict NV region: (1) default (prohibited+ambiguous) to show uniform red +
// stronger grey; (2) with Confirmed-open ON to show uniform green + ambiguity winning over green.
import { chromium } from 'playwright';

const url = process.argv[2] || 'http://localhost:5173';
const browser = await chromium.launch({
  args: ['--enable-unsafe-swiftshader', '--ignore-gpu-blocklist', '--enable-webgl', '--use-gl=angle', '--use-angle=swiftshader'],
});
const page = await browser.newPage({ viewport: { width: 1400, height: 900 } });
page.on('pageerror', (e) => console.log('[pageerror]', e.message));

await page.goto(url, { waitUntil: 'networkidle' }).catch((e) => console.log('[goto]', e.message));
await page.evaluate(() => {
  localStorage.setItem('orescout_ack_accepted', 'true');
  localStorage.setItem('orescout_ack_version', '1.0');
});
await page.reload({ waitUntil: 'networkidle' }).catch(() => {});
await page.waitForTimeout(2000);

// Central NV — BLM (confirmed-open green) + Wilderness (red) + unconfirmed (ambiguous) mix.
const center = [-117.0, 39.3];
async function shot(name, zoom) {
  await page.evaluate((z) => window.__map?.jumpTo({ center: [-117.0, 39.3], zoom: z }), zoom);
  await page.waitForTimeout(5000);
  const counts = await page.evaluate(() => {
    const m = window.__map;
    const q = (l) => { try { return m.queryRenderedFeatures({ layers: [l] }).length; } catch { return -1; } };
    const suffix = m.getZoom() < 9 ? '-lowzoom' : '';
    return {
      zoom: Math.round(m.getZoom() * 10) / 10,
      red: q(`legality-prohibited${suffix}`),
      ambiguous: q(`legality-ambiguous${suffix}`),
      open: q(`legality-open${suffix}`),
    };
  });
  await page.screenshot({ path: `diag_legality_${name}.png` });
  console.log(`  ${name} (z${counts.zoom}): red=${counts.red} ambiguous=${counts.ambiguous} green=${counts.open} -> web/diag_legality_${name}.png`);
}

console.log('1) default layers (prohibited + ambiguous), regional z8:');
await shot('1_default_z8', 8);

console.log('2) + Confirmed open (green) ON — green uniform + ambiguity wins over green:');
await page.getByText('Confirmed open (green)').click();
await page.waitForTimeout(1500);
await shot('2_open_z8', 8);

console.log('3) normal tier z10 (confirmed-open still on):');
await shot('3_open_z10', 10);

await browser.close();
