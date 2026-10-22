// Headless verification of the saved-pin "snapshot + change alert" contract (§6.5).
// Setup (done by diag_snapshot.sh BEFORE this runs):
//   __snap_drift__  — pin whose STORED snapshot was mutated to GREEN, but lives on RED land
//                     → opening it must show the snapshot (Open) + a drift banner (now Prohibited).
//   __snap_stable__ — pin saved on RED land, snapshot untouched (RED)
//                     → opening it shows the snapshot (Prohibited), NO drift banner.
import { chromium } from 'playwright';

const url = process.argv[2] || 'http://localhost:5173';
const browser = await chromium.launch({
  args: ['--enable-unsafe-swiftshader', '--ignore-gpu-blocklist', '--enable-webgl', '--use-gl=angle', '--use-angle=swiftshader'],
});
const page = await browser.newPage({ viewport: { width: 1400, height: 900 } });
page.on('pageerror', (e) => console.log('[pageerror]', e.message));

const results = [];
const ok = (name, cond, detail = '') => results.push({ name, pass: !!cond, detail });

await page.goto(url, { waitUntil: 'networkidle' }).catch((e) => console.log('[goto]', e.message));
await page.evaluate(() => {
  localStorage.setItem('orescout_ack_accepted', 'true');
  localStorage.setItem('orescout_ack_version', '1.0');
});
await page.reload({ waitUntil: 'networkidle' }).catch(() => {});
await page.waitForTimeout(1500);

// Open the "My Pins" tab.
await page.getByRole('button', { name: 'My Pins' }).click();
await page.waitForTimeout(500);

async function openPin(title) {
  await page.locator('.pin-main', { hasText: title }).first().click();
  await page.waitForTimeout(3000); // let the live drift-comparison fetch resolve + render
}
const panel = () => page.locator('.panel.assessment');
async function snap() {
  const p = panel();
  return {
    head: (await p.locator('.panel-head strong').innerText().catch(() => '')).trim(),
    hasSnapshotNote: await p.locator('.snapshot-note').count() > 0,
    hasDrift: await p.locator('.drift').count() > 0,
    verdict: (await p.locator('.verdict-label').innerText().catch(() => '')).trim(),
    hasSaveBtn: await p.getByText('Save this location').count() > 0,
    driftText: await p.locator('.drift').count() > 0 ? (await p.locator('.drift').innerText()).replace(/\s+/g, ' ').trim() : '',
  };
}

// --- Drift pin: snapshot Open, live Prohibited ---
await openPin('__snap_drift__');
const d = await snap();
ok('drift: header is "Saved location"', d.head === 'Saved location', d.head);
ok('drift: shows snapshot-date note', d.hasSnapshotNote);
ok('drift: shows drift banner', d.hasDrift, d.driftText);
ok('drift: verdict label is the SNAPSHOT value (Open)', d.verdict === 'Open', d.verdict);
ok('drift: NO save form (already saved)', !d.hasSaveBtn);

// --- Stable pin: snapshot Prohibited, live Prohibited ---
await openPin('__snap_stable__');
const s = await snap();
ok('stable: shows snapshot-date note', s.hasSnapshotNote);
ok('stable: NO drift banner (saved == current)', !s.hasDrift);
ok('stable: verdict label is Prohibited', s.verdict === 'Prohibited', s.verdict);
ok('stable: NO save form', !s.hasSaveBtn);

// --- Fresh map click: live assessment, save form returns ---
await page.mouse.click(950, 460);
await page.waitForTimeout(3000);
const f = await snap();
ok('live: header is "Location assessment"', f.head === 'Location assessment', f.head);
ok('live: NO snapshot note', !f.hasSnapshotNote);
ok('live: Save form IS present', f.hasSaveBtn);

console.log('\n=== SNAPSHOT + DRIFT CONTRACT ===');
let passed = 0;
for (const r of results) {
  console.log(`${r.pass ? '✓' : '✗ FAIL'}  ${r.name}${r.detail ? `  [${r.detail}]` : ''}`);
  if (r.pass) passed++;
}
console.log(`\n${passed}/${results.length} passed`);
await page.screenshot({ path: 'diag_snapshot.png' });
await browser.close();
process.exit(passed === results.length ? 0 : 1);
